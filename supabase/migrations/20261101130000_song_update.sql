-- Songs ändern über das Upload-Tool, siehe README → Datenmodell → Änderungen.
--
-- 1. Freigabe über einen einzigen Zeitpunkt: song.release_at ist der Moment,
--    ab dem der Song sichtbar ist. approved_at und der Cron-Job dafür fallen weg.
-- 2. Wartende Änderungen sind normale Zeilen in count_in, playback und
--    sheet_music mit release_at (wartet bis) und replaces_id (ersetzt Zeile).
--    Ein stündlicher Job kopiert sie zur Freigabe in die alte Zeile, damit die
--    ID gleich bleibt (Notizen, Downloads und "Zuletzt gespielt" in der App).
-- 3. update_song() legt eine Änderung an, set_file_sha256() trägt fehlende
--    Prüfsummen nach, unused_files() und eine Lösch-Regel räumen den Bucket auf.


-- ---------------------------------------------------------------------------
-- 1. Freigabe-Zeitpunkt
-- ---------------------------------------------------------------------------

-- Erster Zeitpunkt um 4 Uhr (Europe/Berlin), der mindestens 24 Stunden nach
-- dem Upload liegt und nicht vor dem gewünschten Zeitpunkt.
create function private.release_time(uploaded_at timestamptz, wanted_at timestamptz)
returns timestamptz
language sql
stable
set search_path = ''
as $$
    with earliest as (
        select greatest(uploaded_at + interval '24 hours', coalesce(wanted_at, uploaded_at))
            at time zone 'Europe/Berlin' as local_time
    ), candidate as (
        select local_time, date_trunc('day', local_time) + interval '4 hours' as local_release
        from earliest
    )
    select (
        case when local_release < local_time then local_release + interval '1 day' else local_release end
    ) at time zone 'Europe/Berlin'
    from candidate;
$$;

revoke execute on function private.release_time(timestamptz, timestamptz) from public, anon;
grant execute on function private.release_time(timestamptz, timestamptz) to authenticated;

select cron.unschedule('approve_pending_songs');

update song set release_at = coalesce(approved_at, private.release_time(created_at, release_at));
alter table song alter column release_at set not null;

-- release_at kommt als gewünschter Tag (oder null) und wird zum tatsächlichen
-- Freigabe-Zeitpunkt
create or replace function private.prepare_new_song()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.created_at := now();
    new.release_at := private.release_time(new.created_at, new.release_at);
    return new;
end;
$$;

create or replace function private.notify_new_song()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
    category_name text;
begin
    select name into category_name from public.category where id = new.category_id;
    perform private.send_ntfy(
        'Neuer Song wartet auf Freigabe',
        format(
            E'%s (%s)\nHochgeladen: %s\nFreigabe: %s',
            new.name,
            category_name,
            to_char(new.created_at at time zone 'Europe/Berlin', 'DD.MM.YYYY HH24:MI'),
            to_char(new.release_at at time zone 'Europe/Berlin', 'DD.MM.YYYY HH24:MI')
        )
    );
    return new;
end;
$$;

create function private.send_ntfy(title text, message text)
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
    topic text;
begin
    select decrypted_secret into topic
    from vault.decrypted_secrets
    where name = 'ntfy_topic';
    if topic is null then
        raise exception 'Vault-Secret ntfy_topic fehlt';
    end if;
    perform net.http_post(
        url := 'https://ntfy.sh',
        body := jsonb_build_object('topic', topic, 'title', title, 'message', message, 'priority', 4)
    );
end;
$$;

revoke execute on function private.send_ntfy(text, text) from public, anon, authenticated;

drop policy "Angemeldete lesen freigegebene Stuecke" on song;
drop policy "Admins fuegen wartende Stuecke hinzu" on song;
alter table song drop column approved_at;

create policy "Angemeldete lesen freigegebene Stuecke" on song
    for select to authenticated
    using (release_at <= now() or (select private.is_admin()));
create policy "Admins fuegen wartende Stuecke hinzu" on song
    for insert to authenticated
    with check ((select private.is_admin()) and release_at > now());

create or replace function private.song_is_pending(target_song_id bigint)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select exists (
        select 1 from public.song
        where id = target_song_id and release_at > now()
    );
$$;

create or replace function private.song_is_approved(target_song_id bigint)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select exists (
        select 1 from public.song
        where id = target_song_id and release_at <= now()
    );
$$;

create or replace function private.playback_is_pending(target_playback_id bigint)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select exists (
        select 1 from public.playback
        join public.song on song.id = playback.song_id
        where playback.id = target_playback_id and song.release_at > now()
    );
$$;



-- ---------------------------------------------------------------------------
-- 2. Wartende Änderungen als Zeilen
-- ---------------------------------------------------------------------------

alter table count_in add column sha256 text check (sha256 ~ '^[0-9a-f]{64}$');
alter table count_in add column replaces_id bigint references count_in (id) on delete cascade;
alter table count_in add column release_at timestamptz;
alter table count_in add constraint count_in_replaces_only_pending check (replaces_id is null or release_at is not null);

alter table playback add column sha256 text check (sha256 ~ '^[0-9a-f]{64}$');
alter table playback add column replaces_id bigint references playback (id) on delete cascade;
alter table playback add column release_at timestamptz;
alter table playback add constraint playback_replaces_only_pending check (replaces_id is null or release_at is not null);
-- Ändern sich nur Buchstaben oder Sichtbarkeit, bleibt die MP3 dieselbe. Die
-- wartende Zeile hat dann keinen eigenen path (path ist einmalig).
alter table playback alter column path drop not null;
alter table playback add constraint playback_path_check check (path is not null or replaces_id is not null);

alter table sheet_music add column sha256 text check (sha256 ~ '^[0-9a-f]{64}$');
alter table sheet_music add column replaces_id bigint references sheet_music (id) on delete cascade;
alter table sheet_music add column release_at timestamptz;
alter table sheet_music add constraint sheet_music_replaces_only_pending check (replaces_id is null or release_at is not null);

-- Einmalig unter den sichtbaren Zeilen und getrennt davon unter den wartenden
drop index count_in_song_id_lower_name_key;
create unique index count_in_song_id_lower_name_key on count_in (song_id, lower(name)) where release_at is null;
create unique index count_in_pending_song_id_lower_name_key on count_in (song_id, lower(name)) where release_at is not null;

drop index playback_song_id_lower_type_key;
create unique index playback_song_id_lower_type_key on playback (song_id, lower(type)) where release_at is null;
create unique index playback_pending_song_id_lower_type_key on playback (song_id, lower(type)) where release_at is not null;

alter table sheet_music drop constraint sheet_music_song_id_part_id_level_id_key;
create unique index sheet_music_song_id_part_id_level_id_key on sheet_music (song_id, part_id, level_id) where release_at is null;
create unique index sheet_music_pending_song_id_part_id_level_id_key on sheet_music (song_id, part_id, level_id) where release_at is not null;

create unique index count_in_replaces_id_key on count_in (replaces_id) where replaces_id is not null;
create unique index playback_replaces_id_key on playback (replaces_id) where replaces_id is not null;
create unique index sheet_music_replaces_id_key on sheet_music (replaces_id) where replaces_id is not null;

create index count_in_release_at_index on count_in (release_at) where release_at is not null;
create index playback_release_at_index on playback (release_at) where release_at is not null;
create index sheet_music_release_at_index on sheet_music (release_at) where release_at is not null;

-- Die App sieht nur sichtbare Zeilen freigegebener Songs
create or replace function private.playback_is_approved(target_playback_id bigint)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select exists (
        select 1 from public.playback
        join public.song on song.id = playback.song_id
        where playback.id = target_playback_id
            and playback.release_at is null
            and song.release_at <= now()
    );
$$;

drop policy "Angemeldete lesen freigegebene Einzaehler" on count_in;
drop policy "Angemeldete lesen freigegebene Playbacks" on playback;
drop policy "Angemeldete lesen freigegebene Noten" on sheet_music;

create policy "Angemeldete lesen freigegebene Einzaehler" on count_in
    for select to authenticated
    using ((release_at is null and private.song_is_approved(song_id)) or (select private.is_admin()));
create policy "Angemeldete lesen freigegebene Playbacks" on playback
    for select to authenticated
    using ((release_at is null and private.song_is_approved(song_id)) or (select private.is_admin()));
create policy "Angemeldete lesen freigegebene Noten" on sheet_music
    for select to authenticated
    using ((release_at is null and private.song_is_approved(song_id)) or (select private.is_admin()));

create or replace function private.file_is_approved(bucket text, file_name text)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select case bucket
        when 'audio' then exists (
            select 1 from public.playback
            join public.song on song.id = playback.song_id
            where playback.path = file_name and playback.release_at is null and song.release_at <= now()
        ) or exists (
            select 1 from public.count_in
            join public.song on song.id = count_in.song_id
            where count_in.path = file_name and count_in.release_at is null and song.release_at <= now()
        )
        when 'sheet_music' then exists (
            select 1 from public.sheet_music
            join public.song on song.id = sheet_music.song_id
            where sheet_music.path = file_name and sheet_music.release_at is null and song.release_at <= now()
        )
        else false
    end;
$$;


-- ---------------------------------------------------------------------------
-- Änderungen übernehmen
-- ---------------------------------------------------------------------------

-- Übernimmt alle wartenden Zeilen eines Songs. Eine Zeile mit replaces_id
-- wird in die alte Zeile kopiert und dann gelöscht, die alte ID bleibt.
-- Eine Zeile ohne replaces_id wird einfach sichtbar.
create function private.apply_song_changes(target_song_id bigint)
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
    pending_count_in public.count_in;
    pending_playback public.playback;
    pending_sheet public.sheet_music;
begin
    for pending_count_in in
        select * from public.count_in where song_id = target_song_id and release_at is not null order by id
    loop
        if pending_count_in.replaces_id is null then
            update public.count_in set release_at = null where id = pending_count_in.id;
        else
            update public.letter set count_in_id = pending_count_in.replaces_id where count_in_id = pending_count_in.id;
            delete from public.count_in where id = pending_count_in.id;
            update public.count_in
            set name = pending_count_in.name,
                path = pending_count_in.path,
                duration_ms = pending_count_in.duration_ms,
                sha256 = pending_count_in.sha256
            where id = pending_count_in.replaces_id;
        end if;
    end loop;

    for pending_playback in
        select * from public.playback where song_id = target_song_id and release_at is not null order by id
    loop
        if pending_playback.replaces_id is null then
            update public.playback set release_at = null where id = pending_playback.id;
        else
            delete from public.letter where playback_id = pending_playback.replaces_id;
            delete from public.display_playback where playback_id = pending_playback.replaces_id;
            update public.letter set playback_id = pending_playback.replaces_id where playback_id = pending_playback.id;
            update public.display_playback set playback_id = pending_playback.replaces_id where playback_id = pending_playback.id;
            delete from public.playback where id = pending_playback.id;
            update public.playback
            set type = pending_playback.type,
                path = coalesce(pending_playback.path, path),
                duration_ms = pending_playback.duration_ms,
                sha256 = pending_playback.sha256,
                instrument_mode = pending_playback.instrument_mode
            where id = pending_playback.replaces_id;
        end if;
    end loop;

    for pending_sheet in
        select * from public.sheet_music where song_id = target_song_id and release_at is not null order by id
    loop
        if pending_sheet.replaces_id is null then
            update public.sheet_music set release_at = null where id = pending_sheet.id;
        else
            delete from public.sheet_music where id = pending_sheet.id;
            update public.sheet_music
            set path = pending_sheet.path,
                sha256 = pending_sheet.sha256
            where id = pending_sheet.replaces_id;
        end if;
    end loop;

    update public.song set updated_at = now() where id = target_song_id;
end;
$$;

revoke execute on function private.apply_song_changes(bigint) from public, anon, authenticated;

-- Für den Cron-Job: jeder Song einzeln, ein Fehler bei einem Song hält die
-- anderen nicht auf
create function private.apply_due_song_changes()
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
    due_song_id bigint;
begin
    for due_song_id in
        select song_id from public.count_in where release_at <= now()
        union
        select song_id from public.playback where release_at <= now()
        union
        select song_id from public.sheet_music where release_at <= now()
    loop
        begin
            perform private.apply_song_changes(due_song_id);
        exception when others then
            raise warning 'Änderung an Song % nicht übernommen: %', due_song_id, sqlerrm;
        end;
    end loop;
end;
$$;

revoke execute on function private.apply_due_song_changes() from public, anon, authenticated;

select cron.schedule('apply_song_changes', '0 * * * *', $$ select private.apply_due_song_changes() $$);


-- ---------------------------------------------------------------------------
-- 3. Funktionen für das Upload-Tool
-- ---------------------------------------------------------------------------

-- Legt eine Änderung an einem bestehenden Song an. Läuft als Besitzer, weil
-- Admins über RLS keine Zeilen zu freigegebenen Songs hinzufügen dürfen.
-- Prüft deshalb selbst, dass ein Admin aufruft.
--
-- payload: song_id, publisher_name, publisher_url, release_at (gewünschter Tag
-- oder null), count_ins, playbacks, sheet_music. Die Listen enthalten nur neue
-- und geänderte Einträge. Ein Playback mit path null behält seine MP3.
--
-- Gibt den Zeitpunkt zurück, ab dem die Änderungen sichtbar sind.
create function public.update_song(payload jsonb)
returns timestamptz
language plpgsql
security definer set search_path = ''
as $$
declare
    target_song public.song;
    category_name text;
    song_waiting boolean;
    change_release timestamptz;
    count_in_entry jsonb;
    playback_entry jsonb;
    letter_entry jsonb;
    sheet_entry jsonb;
    live_id bigint;
    live_playback public.playback;
    new_playback_id bigint;
    playback_duration integer;
    playback_mode text;
    playback_instrument_ids bigint[];
    letter_position integer;
    previous_position integer;
    letter_count_in_id bigint;
    change_count integer;
    error_text text;
begin
    if not private.is_admin() then
        raise exception 'forbidden';
    end if;
    if jsonb_typeof(payload) is distinct from 'object'
        or jsonb_typeof(payload -> 'count_ins') is distinct from 'array'
        or jsonb_typeof(payload -> 'playbacks') is distinct from 'array'
        or jsonb_typeof(payload -> 'sheet_music') is distinct from 'array' then
        raise exception 'invalid_manifest' using detail = 'payload hat nicht die erwartete Form';
    end if;

    select * into target_song from public.song where id = (payload ->> 'song_id')::bigint for update;
    if not found then
        raise exception 'invalid_manifest' using detail = 'Song gibt es nicht';
    end if;
    song_waiting := target_song.release_at > now();
    change_release := case
        when song_waiting then now()
        else private.release_time(now(), (payload ->> 'release_at')::timestamptz)
    end;

    -- Verlag und Link gelten sofort
    update public.song
    set publisher_name = payload ->> 'publisher_name',
        publisher_url = payload ->> 'publisher_url'
    where id = target_song.id;

    -- Eine schon wartende Änderung wird durch diese ersetzt
    delete from public.playback where song_id = target_song.id and release_at is not null;
    delete from public.sheet_music where song_id = target_song.id and release_at is not null;
    delete from public.count_in where song_id = target_song.id and release_at is not null;

    for count_in_entry in select value from jsonb_array_elements(payload -> 'count_ins') loop
        select id into live_id
        from public.count_in
        where song_id = target_song.id and release_at is null and lower(name) = lower(count_in_entry ->> 'name');
        insert into public.count_in (song_id, name, path, duration_ms, sha256, replaces_id, release_at)
        values (
            target_song.id,
            count_in_entry ->> 'name',
            count_in_entry ->> 'path',
            (count_in_entry ->> 'duration_ms')::integer,
            count_in_entry ->> 'sha256',
            live_id,
            change_release
        );
        live_id := null;
    end loop;

    for playback_entry in select value from jsonb_array_elements(payload -> 'playbacks') loop
        playback_mode := playback_entry ->> 'instrument_mode';
        select coalesce(array_agg(value::bigint), '{}')
        into playback_instrument_ids
        from jsonb_array_elements_text(coalesce(playback_entry -> 'instrument_ids', '[]'));
        if (playback_mode = 'all') <> (cardinality(playback_instrument_ids) = 0)
            or cardinality(playback_instrument_ids) <> (select count(distinct id) from unnest(playback_instrument_ids) as id) then
            raise exception 'invalid_manifest'
                using detail = format('instrument_ids passen nicht zu instrument_mode bei „%s“', playback_entry ->> 'type');
        end if;

        live_playback := null;
        select * into live_playback
        from public.playback
        where song_id = target_song.id and release_at is null and lower(type) = lower(playback_entry ->> 'type');
        if playback_entry ->> 'path' is null and live_playback.id is null then
            raise exception 'invalid_manifest'
                using detail = format('Playback „%s“ ohne MP3, aber es gibt keins zum Ersetzen', playback_entry ->> 'type');
        end if;

        insert into public.playback (song_id, duration_ms, path, type, instrument_mode, sha256, replaces_id, release_at)
        values (
            target_song.id,
            case when playback_entry ->> 'path' is null then live_playback.duration_ms else (playback_entry ->> 'duration_ms')::integer end,
            playback_entry ->> 'path',
            playback_entry ->> 'type',
            playback_mode,
            case when playback_entry ->> 'path' is null then live_playback.sha256 else playback_entry ->> 'sha256' end,
            live_playback.id,
            change_release
        )
        returning id, duration_ms into new_playback_id, playback_duration;

        insert into public.display_playback (instrument_id, playback_id)
        select instrument_id, new_playback_id from unnest(playback_instrument_ids) as instrument_id;

        previous_position := null;
        for letter_entry in select value from jsonb_array_elements(coalesce(playback_entry -> 'letters', '[]')) loop
            letter_position := (letter_entry ->> 'position_ms')::integer;
            if letter_position <= previous_position or letter_position > playback_duration then
                raise exception 'invalid_manifest'
                    using detail = format('Buchstabe „%s“ bei „%s“ nicht aufsteigend oder hinter dem Ende', letter_entry ->> 'name', playback_entry ->> 'type');
            end if;

            -- Erst ein Einzähler aus dieser Änderung, sonst ein sichtbarer
            letter_count_in_id := null;
            select id into letter_count_in_id
            from public.count_in
            where song_id = target_song.id and lower(name) = lower(letter_entry ->> 'count_in')
            order by release_at is null
            limit 1;
            if letter_count_in_id is null then
                raise exception 'invalid_manifest'
                    using detail = format('Einzähler „%s“ fehlt bei „%s“', letter_entry ->> 'count_in', playback_entry ->> 'type');
            end if;

            insert into public.letter (playback_id, name, position_ms, count_in_id)
            values (new_playback_id, letter_entry ->> 'name', letter_position, letter_count_in_id);
            previous_position := letter_position;
        end loop;
    end loop;

    for sheet_entry in select value from jsonb_array_elements(payload -> 'sheet_music') loop
        select id into live_id
        from public.sheet_music
        where song_id = target_song.id
            and release_at is null
            and part_id = (sheet_entry ->> 'part_id')::bigint
            and level_id = (sheet_entry ->> 'level_id')::bigint;
        insert into public.sheet_music (song_id, part_id, level_id, path, sha256, replaces_id, release_at)
        values (
            target_song.id,
            (sheet_entry ->> 'part_id')::bigint,
            (sheet_entry ->> 'level_id')::bigint,
            sheet_entry ->> 'path',
            sheet_entry ->> 'sha256',
            live_id,
            change_release
        );
        live_id := null;
    end loop;

    change_count := jsonb_array_length(payload -> 'count_ins')
        + jsonb_array_length(payload -> 'playbacks')
        + jsonb_array_length(payload -> 'sheet_music');
    if change_count = 0 then
        return now();
    end if;

    -- Wartet der Song noch auf seine erste Freigabe, gilt die Änderung sofort
    if song_waiting then
        perform private.apply_song_changes(target_song.id);
    end if;

    select name into category_name from public.category where id = target_song.category_id;
    perform private.send_ntfy(
        case when song_waiting then 'Wartender Song geändert' else 'Song geändert, wartet auf Freigabe' end,
        format(
            E'%s (%s)\n%s Noten, %s Playbacks, %s Einzähler neu oder geändert\nFreigabe: %s',
            target_song.name,
            category_name,
            jsonb_array_length(payload -> 'sheet_music'),
            jsonb_array_length(payload -> 'playbacks'),
            jsonb_array_length(payload -> 'count_ins'),
            to_char(
                (case when song_waiting then target_song.release_at else change_release end) at time zone 'Europe/Berlin',
                'DD.MM.YYYY HH24:MI'
            )
        )
    );
    return case when song_waiting then target_song.release_at else change_release end;
exception
    when unique_violation or integrity_constraint_violation or data_exception then
        get stacked diagnostics error_text = message_text;
        raise exception 'invalid_manifest' using detail = error_text;
end;
$$;

revoke execute on function public.update_song(jsonb) from public, anon;
grant execute on function public.update_song(jsonb) to authenticated;

-- Trägt die Prüfsumme einer Datei nach, die vor dieser Migration hochgeladen
-- wurde. Überschreibt nie eine vorhandene Prüfsumme.
create function public.set_file_sha256(kind text, row_id bigint, hash text)
returns void
language plpgsql
security definer set search_path = ''
as $$
begin
    if not private.is_admin() then
        raise exception 'forbidden';
    end if;
    if hash !~ '^[0-9a-f]{64}$' then
        raise exception 'invalid_manifest' using detail = 'Prüfsumme ungültig';
    end if;
    case kind
        when 'count_in' then update public.count_in set sha256 = hash where id = row_id and sha256 is null;
        when 'playback' then update public.playback set sha256 = hash where id = row_id and sha256 is null;
        when 'sheet_music' then update public.sheet_music set sha256 = hash where id = row_id and sha256 is null;
        else raise exception 'invalid_manifest' using detail = 'unbekannte Tabelle';
    end case;
end;
$$;

revoke execute on function public.set_file_sha256(text, bigint, text) from public, anon;
grant execute on function public.set_file_sha256(text, bigint, text) to authenticated;

-- Eine Datei im Bucket ist unbenutzt, wenn keine Zeile auf sie zeigt, sie wie
-- eine Datei des Upload-Tools heißt (<uuid>.mp3 / <uuid>.pdf) und älter als
-- eine Stunde ist. So trifft das Aufräumen nie eine Datei, die gerade erst
-- hochgeladen wurde und noch auf ihre Zeile wartet.
create function private.file_is_unused(bucket text, file_name text, uploaded_at timestamptz)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select uploaded_at < now() - interval '1 hour'
        and case bucket
            when 'audio' then file_name ~ '^[0-9a-f-]{36}\.mp3$'
                and not exists (select 1 from public.playback where path = file_name)
                and not exists (select 1 from public.count_in where path = file_name)
            when 'sheet_music' then file_name ~ '^[0-9a-f-]{36}\.pdf$'
                and not exists (select 1 from public.sheet_music where path = file_name)
            else false
        end;
$$;

revoke execute on function private.file_is_unused(text, text, timestamptz) from public, anon;
grant execute on function private.file_is_unused(text, text, timestamptz) to authenticated;

create policy "Admins loeschen unbenutzte Dateien" on storage.objects
    for delete to authenticated
    using (
        bucket_id in ('sheet_music', 'audio')
        and (select private.is_admin())
        and private.file_is_unused(bucket_id, name, created_at)
    );

create function public.unused_files()
returns table (bucket text, name text)
language sql
stable
security definer set search_path = ''
as $$
    select objects.bucket_id, objects.name
    from storage.objects as objects
    where (select private.is_admin())
        and objects.bucket_id in ('sheet_music', 'audio')
        and private.file_is_unused(objects.bucket_id, objects.name, objects.created_at)
    order by objects.bucket_id, objects.name;
$$;

revoke execute on function public.unused_files() from public, anon;
grant execute on function public.unused_files() to authenticated;

-- import_song speichert jetzt die Prüfsummen mit. Sonst unverändert gegenüber
-- 20261101120000_song_publisher.
create or replace function public.import_song(payload jsonb)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
    new_song_id bigint;
    count_in_entry jsonb;
    playback_entry jsonb;
    letter_entry jsonb;
    sheet_entry jsonb;
    new_playback_id bigint;
    playback_duration integer;
    playback_mode text;
    playback_instrument_ids bigint[];
    letter_position integer;
    previous_position integer;
    letter_count_in_id bigint;
    violated_constraint text;
    error_text text;
begin
    if jsonb_typeof(payload) is distinct from 'object'
        or jsonb_typeof(payload -> 'count_ins') is distinct from 'array'
        or jsonb_typeof(payload -> 'playbacks') is distinct from 'array'
        or jsonb_typeof(payload -> 'sheet_music') is distinct from 'array' then
        raise exception 'invalid_manifest' using detail = 'payload hat nicht die erwartete Form';
    end if;
    if jsonb_array_length(payload -> 'playbacks') = 0 and jsonb_array_length(payload -> 'sheet_music') = 0 then
        raise exception 'invalid_manifest' using detail = 'keine Playbacks und keine Noten';
    end if;

    insert into public.song (name, category_id, release_at, publisher_name, publisher_url)
    values (
        payload ->> 'song_name',
        (payload ->> 'category_id')::bigint,
        (payload ->> 'release_at')::timestamptz,
        payload ->> 'publisher_name',
        payload ->> 'publisher_url'
    )
    returning id into new_song_id;

    for count_in_entry in select value from jsonb_array_elements(payload -> 'count_ins') loop
        insert into public.count_in (song_id, name, path, duration_ms, sha256)
        values (
            new_song_id,
            count_in_entry ->> 'name',
            count_in_entry ->> 'path',
            (count_in_entry ->> 'duration_ms')::integer,
            count_in_entry ->> 'sha256'
        );
    end loop;

    for playback_entry in select value from jsonb_array_elements(payload -> 'playbacks') loop
        playback_mode := playback_entry ->> 'instrument_mode';
        select coalesce(array_agg(value::bigint), '{}')
        into playback_instrument_ids
        from jsonb_array_elements_text(coalesce(playback_entry -> 'instrument_ids', '[]'));

        if (playback_mode = 'all') <> (cardinality(playback_instrument_ids) = 0)
            or cardinality(playback_instrument_ids) <> (select count(distinct id) from unnest(playback_instrument_ids) as id) then
            raise exception 'invalid_manifest'
                using detail = format('instrument_ids passen nicht zu instrument_mode bei „%s“', playback_entry ->> 'type');
        end if;

        insert into public.playback (song_id, duration_ms, path, type, instrument_mode, sha256)
        values (
            new_song_id,
            (playback_entry ->> 'duration_ms')::integer,
            playback_entry ->> 'path',
            playback_entry ->> 'type',
            playback_mode,
            playback_entry ->> 'sha256'
        )
        returning id, duration_ms into new_playback_id, playback_duration;

        insert into public.display_playback (instrument_id, playback_id)
        select instrument_id, new_playback_id from unnest(playback_instrument_ids) as instrument_id;

        previous_position := null;
        for letter_entry in select value from jsonb_array_elements(coalesce(playback_entry -> 'letters', '[]')) loop
            letter_position := (letter_entry ->> 'position_ms')::integer;
            if letter_position <= previous_position or letter_position > playback_duration then
                raise exception 'invalid_manifest'
                    using detail = format('Buchstabe „%s“ bei „%s“ nicht aufsteigend oder hinter dem Ende', letter_entry ->> 'name', playback_entry ->> 'type');
            end if;

            letter_count_in_id := null;
            select id into letter_count_in_id
            from public.count_in
            where song_id = new_song_id and lower(name) = lower(letter_entry ->> 'count_in');
            if letter_count_in_id is null then
                raise exception 'invalid_manifest'
                    using detail = format('Einzähler „%s“ fehlt bei „%s“', letter_entry ->> 'count_in', playback_entry ->> 'type');
            end if;

            insert into public.letter (playback_id, name, position_ms, count_in_id)
            values (new_playback_id, letter_entry ->> 'name', letter_position, letter_count_in_id);
            previous_position := letter_position;
        end loop;
    end loop;

    for sheet_entry in select value from jsonb_array_elements(payload -> 'sheet_music') loop
        insert into public.sheet_music (song_id, part_id, level_id, path, sha256)
        values (
            new_song_id,
            (sheet_entry ->> 'part_id')::bigint,
            (sheet_entry ->> 'level_id')::bigint,
            sheet_entry ->> 'path',
            sheet_entry ->> 'sha256'
        );
    end loop;

    return new_song_id;
exception
    when unique_violation then
        get stacked diagnostics violated_constraint = constraint_name, error_text = message_text;
        if violated_constraint = 'song_category_id_lower_name_key' then
            raise exception 'song_exists';
        end if;
        raise exception 'invalid_manifest' using detail = error_text;
    when integrity_constraint_violation or data_exception then
        get stacked diagnostics error_text = message_text;
        raise exception 'invalid_manifest' using detail = error_text;
    when insufficient_privilege then
        raise exception 'forbidden';
end;
$$;

revoke execute on function public.import_song(jsonb) from public, anon;
grant execute on function public.import_song(jsonb) to authenticated;
