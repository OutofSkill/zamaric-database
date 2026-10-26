create function private.is_clean_name(value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
    select value <> ''
        and char_length(value) <= 100
        and value !~ '^[[:space:]]|[[:space:]]$'
        and value !~ '[\u0001-\u001f\u007f-\u009f­؀-؅؜۝܏࢐࢑࣢᠎​-‏‪-‮⁠-⁤⁦-⁯﻿￹-￻\U000110bd\U000110cd\U00013430-\U0001343f\U0001bca0-\U0001bca3\U0001d173-\U0001d17a\U000e0001\U000e0020-\U000e007f]';
$$;

revoke execute on function private.is_clean_name(text) from public, anon;
grant execute on function private.is_clean_name(text) to authenticated;

alter table song add constraint song_name_check check (private.is_clean_name(name));
alter table playback add constraint playback_type_check check (private.is_clean_name(type));
alter table count_in add constraint count_in_name_check check (private.is_clean_name(name));
alter table letter add constraint letter_name_check check (name ~ '^([A-Z]|[0-9]+|D\.S\.|D\.C\.|Coda)$');
alter table letter add constraint letter_position_ms_check check (position_ms >= 0);
alter table playback add constraint playback_duration_ms_check check (duration_ms > 0);
alter table count_in add constraint count_in_duration_ms_check check (duration_ms > 0);

create function public.import_song(payload jsonb)
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

    insert into public.song (name, category_id, release_at)
    values (
        payload ->> 'song_name',
        (payload ->> 'category_id')::bigint,
        (payload ->> 'release_at')::timestamptz
    )
    returning id into new_song_id;

    for count_in_entry in select value from jsonb_array_elements(payload -> 'count_ins') loop
        insert into public.count_in (song_id, name, path, duration_ms)
        values (
            new_song_id,
            count_in_entry ->> 'name',
            count_in_entry ->> 'path',
            (count_in_entry ->> 'duration_ms')::integer
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

        insert into public.playback (song_id, duration_ms, path, type, instrument_mode)
        values (
            new_song_id,
            (playback_entry ->> 'duration_ms')::integer,
            playback_entry ->> 'path',
            playback_entry ->> 'type',
            playback_mode
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
        insert into public.sheet_music (song_id, part_id, level_id, path)
        values (
            new_song_id,
            (sheet_entry ->> 'part_id')::bigint,
            (sheet_entry ->> 'level_id')::bigint,
            sheet_entry ->> 'path'
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
