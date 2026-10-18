alter table song add column release_at timestamptz;

create or replace function private.notify_new_song()
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
    if new.release_at is not null then
        earliest_release := greatest(earliest_release, new.release_at at time zone 'Europe/Berlin');
    end if;
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
                E'%s (%s)\nHochgeladen: %s\nFreigabe: %s%s',
                new.name,
                category_name,
                to_char(new.created_at at time zone 'Europe/Berlin', 'DD.MM.YYYY HH24:MI'),
                to_char(release_time, 'DD.MM.YYYY HH24:MI'),
                case when new.release_at is not null then ' (geplant)' else '' end
            ),
            'priority', 4
        )
    );
    return new;
end;
$$;

revoke execute on function private.notify_new_song() from public, anon, authenticated;

select cron.schedule(
    'approve_pending_songs',
    '0 * * * *',
    $$
    update public.song
    set approved_at = now()
    where approved_at is null
        and created_at <= now() - interval '24 hours'
        and (release_at is null or release_at <= now())
        and extract(hour from now() at time zone 'Europe/Berlin') = 4
    $$
);
