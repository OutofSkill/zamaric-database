create extension if not exists moddatetime schema extensions;

create table category (
    id bigint generated always as identity primary key,
    name text not null unique,
    updated_at timestamptz not null default now()
);

create table song (
    id bigint generated always as identity primary key,
    name text not null,
    category_id bigint not null references category (id),
    updated_at timestamptz not null default now()
);
create index song_name_index on song (name);
create index song_category_id_index on song (category_id);

create table instrument (
    id bigint generated always as identity primary key,
    name text not null,
    transposition text not null,
    updated_at timestamptz not null default now(),
    unique (name, transposition)
);

create table level (
    id bigint generated always as identity primary key,
    name text not null unique,
    updated_at timestamptz not null default now()
);

create table count_in (
    id bigint generated always as identity primary key,
    name text not null unique,
    path text not null unique,
    duration_ms integer not null,
    updated_at timestamptz not null default now()
);

create table playback (
    id bigint generated always as identity primary key,
    song_id bigint not null references song (id),
    duration_ms integer not null,
    path text not null unique,
    type text,
    instrument_mode text not null default 'all'
        check (instrument_mode in ('all', 'only', 'except')),
    updated_at timestamptz not null default now()
);
create index playback_song_id_type_index on playback (song_id, type);

create table letter (
    id bigint generated always as identity primary key,
    playback_id bigint not null references playback (id) on delete cascade,
    name text not null,
    position_ms integer not null,
    count_in_id bigint not null references count_in (id),
    updated_at timestamptz not null default now(),
    unique (playback_id, name)
);
create index letter_count_in_id_index on letter (count_in_id);

create table sheet_music (
    id bigint generated always as identity primary key,
    song_id bigint not null references song (id),
    instrument_id bigint not null references instrument (id),
    level_id bigint not null references level (id),
    path text not null unique,
    updated_at timestamptz not null default now(),
    unique (song_id, instrument_id, level_id)
);
create index sheet_music_instrument_id_index on sheet_music (instrument_id);
create index sheet_music_level_id_index on sheet_music (level_id);

create table display_playback (
    instrument_id bigint not null references instrument (id),
    playback_id bigint not null references playback (id) on delete cascade,
    primary key (instrument_id, playback_id)
);
create index display_playback_playback_id_index on display_playback (playback_id);

create table profiles (
    id uuid primary key references auth.users (id) on delete cascade,
    updated_at timestamptz not null default now()
);

create table user_instrument (
    user_id uuid not null references profiles (id) on delete cascade,
    instrument_id bigint not null references instrument (id),
    primary key (user_id, instrument_id)
);
create index user_instrument_instrument_id_index on user_instrument (instrument_id);

create trigger category_updated_at before update on category
    for each row execute procedure extensions.moddatetime (updated_at);
create trigger song_updated_at before update on song
    for each row execute procedure extensions.moddatetime (updated_at);
create trigger instrument_updated_at before update on instrument
    for each row execute procedure extensions.moddatetime (updated_at);
create trigger level_updated_at before update on level
    for each row execute procedure extensions.moddatetime (updated_at);
create trigger count_in_updated_at before update on count_in
    for each row execute procedure extensions.moddatetime (updated_at);
create trigger playback_updated_at before update on playback
    for each row execute procedure extensions.moddatetime (updated_at);
create trigger letter_updated_at before update on letter
    for each row execute procedure extensions.moddatetime (updated_at);
create trigger sheet_music_updated_at before update on sheet_music
    for each row execute procedure extensions.moddatetime (updated_at);
create trigger profiles_updated_at before update on profiles
    for each row execute procedure extensions.moddatetime (updated_at);

create function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
    insert into public.profiles (id) values (new.id);
    return new;
end;
$$;

create trigger on_auth_user_created after insert on auth.users
    for each row execute procedure public.handle_new_user();

alter table category enable row level security;
alter table song enable row level security;
alter table instrument enable row level security;
alter table level enable row level security;
alter table count_in enable row level security;
alter table playback enable row level security;
alter table letter enable row level security;
alter table sheet_music enable row level security;
alter table display_playback enable row level security;
alter table profiles enable row level security;
alter table user_instrument enable row level security;

create policy "Angemeldete lesen Kategorien" on category
    for select to authenticated using (true);
create policy "Angemeldete lesen Stuecke" on song
    for select to authenticated using (true);
create policy "Angemeldete lesen Instrumente" on instrument
    for select to authenticated using (true);
create policy "Angemeldete lesen Level" on level
    for select to authenticated using (true);
create policy "Angemeldete lesen Einzaehler" on count_in
    for select to authenticated using (true);
create policy "Angemeldete lesen Playbacks" on playback
    for select to authenticated using (true);
create policy "Angemeldete lesen Buchstaben" on letter
    for select to authenticated using (true);
create policy "Angemeldete lesen Noten" on sheet_music
    for select to authenticated using (true);
create policy "Angemeldete lesen Playback-Instrumente" on display_playback
    for select to authenticated using (true);

create policy "Eigenes Profil lesen" on profiles
    for select to authenticated using ((select auth.uid()) = id);
create policy "Eigenes Profil aendern" on profiles
    for update to authenticated
    using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

create policy "Eigene Instrumente lesen" on user_instrument
    for select to authenticated using ((select auth.uid()) = user_id);
create policy "Eigene Instrumente hinzufuegen" on user_instrument
    for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Eigene Instrumente entfernen" on user_instrument
    for delete to authenticated using ((select auth.uid()) = user_id);
