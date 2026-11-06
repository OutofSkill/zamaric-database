-- integrity_report() nach den ersten echten Ergebnissen angepasst:
-- 1. song_without_sheet_music fällt weg. Songs ohne Noten sind teilweise gewollt.
-- 2. duplicate_file bei Noten: Dasselbe Blatt mehrfach in einem Song ist gewollt
--    (z. B. ein Akkordeonblatt für mehrere Stimmen). Gemeldet wird erst, wenn in
--    einem Song zwei oder mehr verschiedene Dateien doppelt vorkommen oder wenn
--    dieselbe Datei in verschiedenen Songs steckt. Bei Playbacks und Einzählern
--    bleibt es bei jeder doppelten Prüfsumme in der Tabelle.
-- Sonst unverändert gegenüber 20261106120000_dev_site.

create or replace function public.integrity_report()
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
        -- Dieselbe Datei mehrfach in einer Tabelle (Playbacks und Einzähler)
        select 'duplicate_file', 'warning', file.table_name, file.row_id, file.song_id,
            format('Prüfsumme %s kommt %s-mal vor', left(file.sha256, 12), duplicates.copies)
        from private.file_rows() as file
        join (
            select file_rows.table_name, file_rows.sha256, count(*) as copies
            from private.file_rows() as file_rows
            where file_rows.path is not null and file_rows.sha256 is not null
                and file_rows.table_name <> 'sheet_music'
            group by file_rows.table_name, file_rows.sha256
            having count(*) > 1
        ) as duplicates on duplicates.table_name = file.table_name and duplicates.sha256 = file.sha256
        where file.path is not null

        union all
        -- Noten: dieselbe Datei in verschiedenen Songs, oder in einem Song zwei
        -- oder mehr verschiedene Dateien, die jeweils doppelt vorkommen
        select 'duplicate_file', 'warning', 'sheet_music', sheet_music.id, sheet_music.song_id,
            case
                when shared.sha256 is not null then
                    format('Prüfsumme %s auch in %s anderen Song(s)', left(sheet_music.sha256, 12), shared.songs - 1)
                else
                    format('Prüfsumme %s kommt %s-mal vor, %s doppelte Dateien im Song',
                        left(sheet_music.sha256, 12), in_song.copies, in_song.duplicate_groups)
            end
        from public.sheet_music as sheet_music
        left join (
            select sheets.sha256, count(distinct sheets.song_id) as songs
            from public.sheet_music as sheets
            where sheets.path is not null and sheets.sha256 is not null
            group by sheets.sha256
            having count(distinct sheets.song_id) > 1
        ) as shared on shared.sha256 = sheet_music.sha256
        left join (
            select grouped.song_id, grouped.sha256, grouped.copies, grouped.duplicate_groups
            from (
                select sheets.song_id, sheets.sha256, count(*) as copies,
                    count(*) over (partition by sheets.song_id) as duplicate_groups
                from public.sheet_music as sheets
                where sheets.path is not null and sheets.sha256 is not null
                group by sheets.song_id, sheets.sha256
                having count(*) > 1
            ) as grouped
            where grouped.duplicate_groups >= 2
        ) as in_song on in_song.song_id = sheet_music.song_id and in_song.sha256 = sheet_music.sha256
        where sheet_music.path is not null
            and (shared.sha256 is not null or in_song.sha256 is not null)

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
