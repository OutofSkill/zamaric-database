revoke execute on function public.handle_new_user() from public, anon, authenticated;

create table admin (
    id uuid primary key references profiles (id) on delete cascade
);
alter table admin enable row level security;

create schema if not exists private;
grant usage on schema private to authenticated;

create function private.is_admin()
returns boolean
language sql
stable
security definer set search_path = ''
as $$
    select exists (
        select 1 from public.admin where id = (select auth.uid())
    );
$$;

revoke execute on function private.is_admin() from public, anon;
grant execute on function private.is_admin() to authenticated;

create policy "Admins verwalten Kategorien" on category
    for all to authenticated
    using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins verwalten Stuecke" on song
    for all to authenticated
    using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins verwalten Instrumente" on instrument
    for all to authenticated
    using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins verwalten Level" on level
    for all to authenticated
    using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins verwalten Einzaehler" on count_in
    for all to authenticated
    using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins verwalten Playbacks" on playback
    for all to authenticated
    using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins verwalten Buchstaben" on letter
    for all to authenticated
    using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins verwalten Noten" on sheet_music
    for all to authenticated
    using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admins verwalten Playback-Instrumente" on display_playback
    for all to authenticated
    using ((select private.is_admin())) with check ((select private.is_admin()));

create policy "Admins verwalten Dateien" on storage.objects
    for all to authenticated
    using (bucket_id in ('sheet_music', 'audio') and (select private.is_admin()))
    with check (bucket_id in ('sheet_music', 'audio') and (select private.is_admin()));
