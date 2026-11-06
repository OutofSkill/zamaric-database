-- Entwicklerseite (Backend/dev), siehe README → Entwicklerseite.
--
-- 1. Nachrichten: send_ntfy() schreibt jede Nachricht zusätzlich in die
--    Tabelle notification. Das Topic bleibt im Vault, ntfy.sh hebt
--    Nachrichten nur 12 Stunden auf.
-- 2. Funktionen für die Bereiche Datenbank und Nachrichten. Sie lesen nur,
--    laufen als Besitzer und prüfen deshalb selbst, dass ein Admin aufruft.
--    Dateien im Bucket werden hier nur gelesen, gelöscht wird über die
--    Storage-API (unused_files() und die bestehende Lösch-Regel).
--
-- Das Board der Entwicklerseite liegt nicht hier, sondern in einer
-- SQLite-Datei auf dem Pi (Backend/dev/api/board.py).


-- ---------------------------------------------------------------------------
-- 1. Nachrichten
-- ---------------------------------------------------------------------------

-- Jede Nachricht an ntfy. request_id zeigt auf net._http_response, dort
-- steht für ein paar Stunden, ob ntfy.sh sie angenommen hat.
create table notification (
    id bigint generated always as identity primary key,
    title text not null,
    message text not null,
    request_id bigint,
    sent_at timestamptz not null default now()
);
create index notification_sent_at_index on notification (sent_at);

alter table notification enable row level security;

-- Nur lesen: Zeilen schreibt ausschließlich send_ntfy()
create policy "Admins lesen Nachrichten" on notification
    for select to authenticated
    using ((select private.is_admin()));

-- Wie in 20261101130000_song_update, schreibt zusätzlich die Nachricht mit.
-- pg_net sendet erst nach dem Commit. Scheitert das Anlegen eines Songs,
-- verschwindet also auch die Zeile hier.
create or replace function private.send_ntfy(title text, message text)
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
    topic text;
    new_request_id bigint;
begin
    select decrypted_secret into topic
    from vault.decrypted_secrets
    where name = 'ntfy_topic';
    if topic is null then
        raise exception 'Vault-Secret ntfy_topic fehlt';
    end if;
    new_request_id := net.http_post(
        url := 'https://ntfy.sh',
        body := jsonb_build_object('topic', topic, 'title', send_ntfy.title, 'message', send_ntfy.message, 'priority', 4)
    );
    insert into public.notification (title, message, request_id)
    values (send_ntfy.title, send_ntfy.message, new_request_id);
end;
$$;

revoke execute on function private.send_ntfy(text, text) from public, anon, authenticated;

-- Die letzten Nachrichten, neueste zuerst. status_code ist null, solange
-- pg_net keine Antwort hat oder nachdem es sie gelöscht hat (nach 6 Stunden).
create function public.notification_feed(max_rows integer default 200)
returns table (id bigint, title text, message text, sent_at timestamptz, status_code integer)
language plpgsql
stable
security definer set search_path = ''
as $$
#variable_conflict use_column
begin
    if not private.is_admin() then
        raise exception 'forbidden';
    end if;
    return query
    select notification.id, notification.title, notification.message, notification.sent_at, response.status_code
    from public.notification as notification
    left join net._http_response as response on response.id = notification.request_id
    order by notification.sent_at desc, notification.id desc
    limit greatest(least(max_rows, 1000), 1);
end;
$$;

revoke execute on function public.notification_feed(integer) from public, anon;
grant execute on function public.notification_feed(integer) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. Bereich Datenbank
-- ---------------------------------------------------------------------------

-- Alle Datei-Zeilen mit Bucket, auch wartende
create function private.file_rows()
returns table (table_name text, row_id bigint, song_id bigint, bucket text, path text, sha256 text)
language sql
stable
security definer set search_path = ''
as $$
    select 'count_in'::text, count_in.id, count_in.song_id, 'audio'::text, count_in.path, count_in.sha256
    from public.count_in
    union all
    select 'playback'::text, playback.id, playback.song_id, 'audio'::text, playback.path, playback.sha256
    from public.playback
    union all
    select 'sheet_music'::text, sheet_music.id, sheet_music.song_id, 'sheet_music'::text, sheet_music.path, sheet_music.sha256
    from public.sheet_music;
$$;

revoke execute on function private.file_rows() from public, anon, authenticated;

-- Zeilen, deren Datei im Bucket fehlt. Wartende Playbacks ohne eigene MP3
-- (path null) behalten die Datei der alten Zeile und zählen nicht.
create function public.missing_files()
returns table (table_name text, row_id bigint, song_id bigint, song_name text, bucket text, path text)
language plpgsql
stable
security definer set search_path = ''
as $$
#variable_conflict use_column
begin
    if not private.is_admin() then
        raise exception 'forbidden';
    end if;
    return query
    select file.table_name, file.row_id, file.song_id, song.name, file.bucket, file.path
    from private.file_rows() as file
    left join public.song as song on song.id = file.song_id
    where file.path is not null
        and not exists (
            select 1 from storage.objects as objects
            where objects.bucket_id = file.bucket and objects.name = file.path
        )
    order by file.table_name, file.row_id;
end;
$$;

revoke execute on function public.missing_files() from public, anon;
grant execute on function public.missing_files() to authenticated;

-- Prüft die Daten auf Widersprüche, die keine Constraint abfängt.
-- severity: 'error' (stört die App oder den Ablauf) oder 'warning' (auffällig).
-- Neue Songs werden über song.release_at sichtbar, ohne Cron-Job. Überfällig
-- können deshalb nur wartende Datei-Zeilen sein, die der stündliche Job
-- apply_song_changes hätte übernehmen müssen.
create function public.integrity_report()
returns table (check_name text, severity text, table_name text, row_id bigint, song_id bigint, song_name text, detail text)
language plpgsql
stable
security definer set search_path = ''
as $$
#variable_conflict use_column
begin
    if not private.is_admin() then
        raise exception 'forbidden';
    end if;
    return query
    with findings (check_name, severity, table_name, row_id, song_id, detail) as (
        -- Sichtbarer Song ohne sichtbares Playback. Nur Warnung: import_song
        -- erlaubt Songs mit nur Noten.
        select 'song_without_playback', 'warning', 'song', song.id, song.id, null::text
        from public.song as song
        where (song.release_at is null or song.release_at <= now())
        and not exists (
            select 1 from public.playback as playback
            where playback.song_id = song.id and playback.release_at is null
        )

        union all
        -- Sichtbarer Song ohne sichtbare Noten
        select 'song_without_sheet_music', 'warning', 'song', song.id, song.id, null::text
        from public.song as song
        where (song.release_at is null or song.release_at <= now())
        and not exists (
            select 1 from public.sheet_music as sheet_music
            where sheet_music.song_id = song.id and sheet_music.release_at is null
        )

        union all
        -- Buchstabe vor dem Anfang oder hinter dem Ende des Playbacks. Genau am
        -- Ende ist erlaubt, wie beim Upload (upload.py, import_song, update_song).
        select 'letter_out_of_range', 'error', 'letter', letter.id, playback.song_id,
            format('Buchstabe %s bei %s ms, Playback %s ms lang', letter.name, letter.position_ms, playback.duration_ms)
        from public.letter as letter
        join public.playback as playback on playback.id = letter.playback_id
        where letter.position_ms < 0 or letter.position_ms > playback.duration_ms

        union all
        -- Einzähler eines anderen Songs
        select 'letter_count_in_other_song', 'error', 'letter', letter.id, playback.song_id,
            format('Buchstabe %s nutzt Einzähler %s von Song %s', letter.name, count_in.id, count_in.song_id)
        from public.letter as letter
        join public.playback as playback on playback.id = letter.playback_id
        join public.count_in as count_in on count_in.id = letter.count_in_id
        where count_in.song_id <> playback.song_id

        union all
        -- Sichtbarer Einzähler, den kein Buchstabe benutzt
        select 'count_in_unused', 'warning', 'count_in', count_in.id, count_in.song_id,
            format('Einzähler %s', count_in.name)
        from public.count_in as count_in
        where count_in.release_at is null
            and not exists (select 1 from public.letter as letter where letter.count_in_id = count_in.id)

        union all
        -- Datei ohne Prüfsumme
        select 'missing_sha256', 'warning', file.table_name, file.row_id, file.song_id, file.path
        from private.file_rows() as file
        where file.path is not null and file.sha256 is null

        union all
        -- Datei fehlt im Bucket
        select 'file_missing', 'error', file.table_name, file.row_id, file.song_id,
            format('%s/%s', file.bucket, file.path)
        from private.file_rows() as file
        where file.path is not null
            and not exists (
                select 1 from storage.objects as objects
                where objects.bucket_id = file.bucket and objects.name = file.path
            )

        union all
        -- Dieselbe Datei mehrfach in einer Tabelle
        select 'duplicate_file', 'warning', file.table_name, file.row_id, file.song_id,
            format('Prüfsumme %s kommt %s-mal vor', left(file.sha256, 12), duplicates.copies)
        from private.file_rows() as file
        join (
            select file_rows.table_name, file_rows.sha256, count(*) as copies
            from private.file_rows() as file_rows
            where file_rows.path is not null and file_rows.sha256 is not null
            group by file_rows.table_name, file_rows.sha256
            having count(*) > 1
        ) as duplicates on duplicates.table_name = file.table_name and duplicates.sha256 = file.sha256
        where file.path is not null

        union all
        -- Wartende Änderung, die längst hätte übernommen sein müssen
        select 'release_overdue', 'error', pending.table_name, pending.row_id, pending.song_id,
            format('Freigabe war %s', to_char(pending.release_at at time zone 'Europe/Berlin', 'DD.MM.YYYY HH24:MI'))
        from (
            select 'count_in'::text as table_name, count_in.id as row_id, count_in.song_id, count_in.release_at
            from public.count_in as count_in
            union all
            select 'playback', playback.id, playback.song_id, playback.release_at
            from public.playback as playback
            union all
            select 'sheet_music', sheet_music.id, sheet_music.song_id, sheet_music.release_at
            from public.sheet_music as sheet_music
        ) as pending
        where pending.release_at < now() - interval '2 hours'

        union all
        -- Wartende Zeile ersetzt eine Zeile eines anderen Songs
        select 'replaces_other_song', 'error', 'count_in', count_in.id, count_in.song_id,
            format('ersetzt Zeile %s von Song %s', replaced.id, replaced.song_id)
        from public.count_in as count_in
        join public.count_in as replaced on replaced.id = count_in.replaces_id
        where replaced.song_id <> count_in.song_id
        union all
        select 'replaces_other_song', 'error', 'playback', playback.id, playback.song_id,
            format('ersetzt Zeile %s von Song %s', replaced.id, replaced.song_id)
        from public.playback as playback
        join public.playback as replaced on replaced.id = playback.replaces_id
        where replaced.song_id <> playback.song_id
        union all
        select 'replaces_other_song', 'error', 'sheet_music', sheet_music.id, sheet_music.song_id,
            format('ersetzt Zeile %s von Song %s', replaced.id, replaced.song_id)
        from public.sheet_music as sheet_music
        join public.sheet_music as replaced on replaced.id = sheet_music.replaces_id
        where replaced.song_id <> sheet_music.song_id

        union all
        -- Länge 0 oder negativ
        select 'invalid_duration', 'error', 'count_in', count_in.id, count_in.song_id,
            format('%s ms', count_in.duration_ms)
        from public.count_in as count_in
        where count_in.duration_ms <= 0
        union all
        select 'invalid_duration', 'error', 'playback', playback.id, playback.song_id,
            format('%s ms', playback.duration_ms)
        from public.playback as playback
        where playback.duration_ms <= 0

        union all
        -- Sichtbarkeit für einzelne Instrumente, obwohl das Playback alle sehen
        select 'display_without_effect', 'warning', 'playback', playback.id, playback.song_id,
            format('%s Instrument(e) eingetragen, Modus all', count(*))
        from public.display_playback as display
        join public.playback as playback on playback.id = display.playback_id
        where playback.instrument_mode = 'all'
        group by playback.id, playback.song_id

        union all
        -- Kategorie ohne Songs
        select 'category_empty', 'warning', 'category', category.id, null::bigint,
            format('Kategorie %s', category.name)
        from public.category as category
        where not exists (select 1 from public.song as song where song.category_id = category.id)
    )
    select findings.check_name, findings.severity, findings.table_name, findings.row_id,
        findings.song_id, song.name, findings.detail
    from findings
    left join public.song as song on song.id = findings.song_id
    order by
        case findings.severity when 'error' then 0 else 1 end,
        findings.check_name,
        song.name nulls last,
        findings.row_id;
end;
$$;

revoke execute on function public.integrity_report() from public, anon;
grant execute on function public.integrity_report() to authenticated;

-- Belegter Speicher je Bucket (Größe laut Metadaten von Supabase Storage)
create function public.storage_usage()
returns table (bucket text, file_count bigint, total_bytes bigint)
language plpgsql
stable
security definer set search_path = ''
as $$
#variable_conflict use_column
begin
    if not private.is_admin() then
        raise exception 'forbidden';
    end if;
    return query
    select buckets.bucket, count(objects.id), coalesce(sum((objects.metadata ->> 'size')::bigint), 0)::bigint
    from (values ('audio'::text), ('sheet_music'::text)) as buckets (bucket)
    left join storage.objects as objects on objects.bucket_id = buckets.bucket
    group by buckets.bucket
    order by buckets.bucket;
end;
$$;

revoke execute on function public.storage_usage() from public, anon;
grant execute on function public.storage_usage() to authenticated;

-- Die größten Dateien, mit der Zeile, die auf sie zeigt (null = unbenutzt)
create function public.largest_files(max_rows integer default 20)
returns table (bucket text, name text, bytes bigint, created_at timestamptz, table_name text, song_name text)
language plpgsql
stable
security definer set search_path = ''
as $$
#variable_conflict use_column
begin
    if not private.is_admin() then
        raise exception 'forbidden';
    end if;
    return query
    with files as (
        -- Einmal berechnet statt je Datei: file_rows() wird als security
        -- definer nicht in die Abfrage eingebettet
        select distinct on (file_rows.bucket, file_rows.path)
            file_rows.bucket, file_rows.path, file_rows.table_name, file_rows.song_id
        from private.file_rows() as file_rows
        where file_rows.path is not null
        order by file_rows.bucket, file_rows.path, file_rows.row_id
    )
    select objects.bucket_id, objects.name, (objects.metadata ->> 'size')::bigint, objects.created_at,
        file.table_name, song.name
    from storage.objects as objects
    left join files as file on file.bucket = objects.bucket_id and file.path = objects.name
    left join public.song as song on song.id = file.song_id
    where objects.bucket_id in ('audio', 'sheet_music')
    order by (objects.metadata ->> 'size')::bigint desc nulls last, objects.name
    limit greatest(least(max_rows, 200), 1);
end;
$$;

revoke execute on function public.largest_files(integer) from public, anon;
grant execute on function public.largest_files(integer) to authenticated;

-- Wartende Freigaben: neue Songs vor ihrem release_at und Songs mit
-- wartenden Änderungen. Bei neuen Songs zählen alle Dateien, sonst nur die
-- wartenden.
create function public.pending_releases()
returns table (song_id bigint, song_name text, category_name text, release_at timestamptz, is_new_song boolean, count_ins integer, playbacks integer, sheet_music integer)
language plpgsql
stable
security definer set search_path = ''
as $$
#variable_conflict use_column
begin
    if not private.is_admin() then
        raise exception 'forbidden';
    end if;
    return query
    with pending as (
        select song.id, song.name, song.category_id, song.release_at > now() as is_new,
            case when song.release_at > now() then song.release_at else (
                select min(changes.release_at)
                from (
                    select count_in.release_at from public.count_in as count_in where count_in.song_id = song.id
                    union all
                    select playback.release_at from public.playback as playback where playback.song_id = song.id
                    union all
                    select sheet_music.release_at from public.sheet_music as sheet_music where sheet_music.song_id = song.id
                ) as changes
            ) end as release_at
        from public.song as song
        where song.release_at > now()
            or exists (select 1 from public.count_in as count_in where count_in.song_id = song.id and count_in.release_at is not null)
            or exists (select 1 from public.playback as playback where playback.song_id = song.id and playback.release_at is not null)
            or exists (select 1 from public.sheet_music as sheet_music where sheet_music.song_id = song.id and sheet_music.release_at is not null)
    )
    select pending.id, pending.name, category.name, pending.release_at, pending.is_new,
        (select count(*) from public.count_in as count_in
            where count_in.song_id = pending.id and (pending.is_new or count_in.release_at is not null))::integer,
        (select count(*) from public.playback as playback
            where playback.song_id = pending.id and (pending.is_new or playback.release_at is not null))::integer,
        (select count(*) from public.sheet_music as sheet_music
            where sheet_music.song_id = pending.id and (pending.is_new or sheet_music.release_at is not null))::integer
    from pending
    join public.category as category on category.id = pending.category_id
    order by pending.release_at, pending.name;
end;
$$;

revoke execute on function public.pending_releases() from public, anon;
grant execute on function public.pending_releases() to authenticated;

-- Die letzten Läufe aller Cron-Jobs (z. B. apply_song_changes), neueste zuerst
create function public.cron_runs(max_rows integer default 50)
returns table (job_name text, status text, started_at timestamptz, finished_at timestamptz, message text)
language plpgsql
stable
security definer set search_path = ''
as $$
#variable_conflict use_column
begin
    if not private.is_admin() then
        raise exception 'forbidden';
    end if;
    return query
    select job.jobname::text, details.status::text, details.start_time, details.end_time, details.return_message::text
    from cron.job_run_details as details
    left join cron.job as job on job.jobid = details.jobid
    order by details.start_time desc nulls last, details.runid desc
    limit greatest(least(max_rows, 500), 1);
end;
$$;

revoke execute on function public.cron_runs(integer) from public, anon;
grant execute on function public.cron_runs(integer) to authenticated;
