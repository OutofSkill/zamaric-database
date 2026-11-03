-- Fingerabdruck über alles, was die App abgleicht.
-- Die App fragt ihn alle paar Minuten ab und holt die Tabellen nur, wenn er sich geändert hat.
-- security invoker: Die Lese-Policies gelten, jeder Account bekommt den Abdruck seiner eigenen Sicht.
-- Damit ändert er sich auch, wenn ein wartender Song seine Freigabezeit erreicht.

create function public.content_version()
returns text
language sql
stable
security invoker
set search_path = ''
as $$
    select md5(concat_ws('|',
        (select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from public.category t),
        (select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from public.song t),
        (select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from public.playback t),
        (select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from public.count_in t),
        (select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from public.letter t),
        (select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from public.display_playback t),
        (select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from public.sheet_music t),
        (select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from public.instrument t),
        (select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from public.part t),
        (select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from public.level t),
        (select md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from public.instrument_part t)
    ));
$$;

revoke execute on function public.content_version() from public, anon;
grant execute on function public.content_version() to authenticated;
