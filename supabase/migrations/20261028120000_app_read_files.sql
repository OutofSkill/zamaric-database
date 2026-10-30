create function private.file_is_approved(bucket text, file_name text)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select case bucket
        when 'audio' then exists (
            select 1 from public.playback
            join public.song on song.id = playback.song_id
            where playback.path = file_name and song.approved_at is not null
        ) or exists (
            select 1 from public.count_in
            join public.song on song.id = count_in.song_id
            where count_in.path = file_name and song.approved_at is not null
        )
        when 'sheet_music' then exists (
            select 1 from public.sheet_music
            join public.song on song.id = sheet_music.song_id
            where sheet_music.path = file_name and song.approved_at is not null
        )
        else false
    end;
$$;

revoke execute on function private.file_is_approved(text, text) from public, anon;
grant execute on function private.file_is_approved(text, text) to authenticated;

create policy "Angemeldete lesen freigegebene Dateien" on storage.objects
    for select to authenticated
    using (bucket_id in ('sheet_music', 'audio') and private.file_is_approved(bucket_id, name));
