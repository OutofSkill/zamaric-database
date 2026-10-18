create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

alter table song add column created_at timestamptz not null default now();
alter table song add column approved_at timestamptz;

create function private.prepare_new_song()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.created_at := now();
    new.approved_at := null;
    return new;
end;
$$;

revoke execute on function private.prepare_new_song() from public, anon, authenticated;

create trigger song_prepare_new before insert on song
    for each row execute procedure private.prepare_new_song();

create function private.song_is_pending(target_song_id bigint)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select exists (
        select 1 from public.song
        where id = target_song_id and approved_at is null
    );
$$;

create function private.song_is_approved(target_song_id bigint)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select exists (
        select 1 from public.song
        where id = target_song_id and approved_at is not null
    );
$$;

create function private.playback_is_pending(target_playback_id bigint)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select exists (
        select 1 from public.playback
        join public.song on song.id = playback.song_id
        where playback.id = target_playback_id and song.approved_at is null
    );
$$;

create function private.playback_is_approved(target_playback_id bigint)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select exists (
        select 1 from public.playback
        join public.song on song.id = playback.song_id
        where playback.id = target_playback_id and song.approved_at is not null
    );
$$;

revoke execute on function private.song_is_pending(bigint) from public, anon;
revoke execute on function private.song_is_approved(bigint) from public, anon;
revoke execute on function private.playback_is_pending(bigint) from public, anon;
revoke execute on function private.playback_is_approved(bigint) from public, anon;
grant execute on function private.song_is_pending(bigint) to authenticated;
grant execute on function private.song_is_approved(bigint) to authenticated;
grant execute on function private.playback_is_pending(bigint) to authenticated;
grant execute on function private.playback_is_approved(bigint) to authenticated;

drop policy "Admins verwalten Kategorien" on category;
drop policy "Admins verwalten Stuecke" on song;
drop policy "Admins verwalten Instrumente" on instrument;
drop policy "Admins verwalten Level" on level;
drop policy "Admins verwalten Einzaehler" on count_in;
drop policy "Admins verwalten Playbacks" on playback;
drop policy "Admins verwalten Buchstaben" on letter;
drop policy "Admins verwalten Noten" on sheet_music;
drop policy "Admins verwalten Playback-Instrumente" on display_playback;
drop policy "Admins verwalten Dateien" on storage.objects;

drop policy "Angemeldete lesen Stuecke" on song;
drop policy "Angemeldete lesen Einzaehler" on count_in;
drop policy "Angemeldete lesen Playbacks" on playback;
drop policy "Angemeldete lesen Buchstaben" on letter;
drop policy "Angemeldete lesen Noten" on sheet_music;
drop policy "Angemeldete lesen Playback-Instrumente" on display_playback;

create policy "Angemeldete lesen freigegebene Stuecke" on song
    for select to authenticated
    using (approved_at is not null or (select private.is_admin()));
create policy "Angemeldete lesen freigegebene Einzaehler" on count_in
    for select to authenticated
    using (private.song_is_approved(song_id) or (select private.is_admin()));
create policy "Angemeldete lesen freigegebene Playbacks" on playback
    for select to authenticated
    using (private.song_is_approved(song_id) or (select private.is_admin()));
create policy "Angemeldete lesen freigegebene Buchstaben" on letter
    for select to authenticated
    using (private.playback_is_approved(playback_id) or (select private.is_admin()));
create policy "Angemeldete lesen freigegebene Noten" on sheet_music
    for select to authenticated
    using (private.song_is_approved(song_id) or (select private.is_admin()));
create policy "Angemeldete lesen freigegebene Playback-Instrumente" on display_playback
    for select to authenticated
    using (private.playback_is_approved(playback_id) or (select private.is_admin()));

create policy "Admins fuegen wartende Stuecke hinzu" on song
    for insert to authenticated
    with check ((select private.is_admin()) and approved_at is null);
create policy "Admins fuegen Einzaehler zu wartenden Stuecken hinzu" on count_in
    for insert to authenticated
    with check ((select private.is_admin()) and private.song_is_pending(song_id));
create policy "Admins fuegen Playbacks zu wartenden Stuecken hinzu" on playback
    for insert to authenticated
    with check ((select private.is_admin()) and private.song_is_pending(song_id));
create policy "Admins fuegen Buchstaben zu wartenden Stuecken hinzu" on letter
    for insert to authenticated
    with check ((select private.is_admin()) and private.playback_is_pending(playback_id));
create policy "Admins fuegen Noten zu wartenden Stuecken hinzu" on sheet_music
    for insert to authenticated
    with check ((select private.is_admin()) and private.song_is_pending(song_id));
create policy "Admins fuegen Playback-Instrumente zu wartenden Stuecken hinzu" on display_playback
    for insert to authenticated
    with check ((select private.is_admin()) and private.playback_is_pending(playback_id));

create policy "Admins lesen Dateien" on storage.objects
    for select to authenticated
    using (bucket_id in ('sheet_music', 'audio') and (select private.is_admin()));
create policy "Admins fuegen Dateien hinzu" on storage.objects
    for insert to authenticated
    with check (bucket_id in ('sheet_music', 'audio') and (select private.is_admin()));

create function private.notify_new_song()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
    topic text;
    category_name text;
    earliest_release timestamp;
    release_time timestamp;
begin
    select decrypted_secret into topic
    from vault.decrypted_secrets
    where name = 'ntfy_topic';
    if topic is null then
        raise exception 'Vault-Secret ntfy_topic fehlt';
    end if;

    select name into category_name from public.category where id = new.category_id;

    earliest_release := (new.created_at + interval '24 hours') at time zone 'Europe/Berlin';
    release_time := date_trunc('day', earliest_release) + interval '4 hours';
    if release_time < earliest_release then
        release_time := release_time + interval '1 day';
    end if;

    perform net.http_post(
        url := 'https://ntfy.sh',
        body := jsonb_build_object(
            'topic', topic,
            'title', 'Neuer Song wartet auf Freigabe',
            'message', format(
                E'%s (%s)\nHochgeladen: %s\nFreigabe: %s',
                new.name,
                category_name,
                to_char(new.created_at at time zone 'Europe/Berlin', 'DD.MM.YYYY HH24:MI'),
                to_char(release_time, 'DD.MM.YYYY HH24:MI')
            ),
            'priority', 4
        )
    );
    return new;
end;
$$;

revoke execute on function private.notify_new_song() from public, anon, authenticated;

create trigger song_notify_new after insert on song
    for each row execute procedure private.notify_new_song();

select cron.schedule(
    'approve_pending_songs',
    '0 * * * *',
    $$
    update public.song
    set approved_at = now()
    where approved_at is null
        and created_at <= now() - interval '24 hours'
        and extract(hour from now() at time zone 'Europe/Berlin') = 4
    $$
);
