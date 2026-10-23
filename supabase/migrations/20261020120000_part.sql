create table part (
    id bigint generated always as identity primary key,
    name text not null,
    transposition text not null,
    for_whole_transposition boolean not null default false,
    updated_at timestamptz not null default now()
);
create unique index part_lower_name_transposition_key on part (lower(name), lower(transposition));

create trigger part_updated_at before update on part
    for each row execute procedure extensions.moddatetime (updated_at);

create table part_instrument (
    part_id bigint not null references part (id) on delete cascade,
    instrument_id bigint not null references instrument (id) on delete cascade,
    primary key (part_id, instrument_id)
);
create index part_instrument_instrument_id_index on part_instrument (instrument_id);

alter table part enable row level security;
alter table part_instrument enable row level security;

create policy "Angemeldete lesen Stimmen" on part
    for select to authenticated using (true);
create policy "Angemeldete lesen Stimmen-Instrumente" on part_instrument
    for select to authenticated using (true);

alter table sheet_music drop column instrument_id;
alter table sheet_music add column part_id bigint not null references part (id);
alter table sheet_music add constraint sheet_music_song_id_part_id_level_id_key unique (song_id, part_id, level_id);
create index sheet_music_part_id_index on sheet_music (part_id);

create function private.create_default_part()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    default_part_id bigint;
begin
    insert into public.part (name, transposition)
    values (new.name, new.transposition)
    on conflict do nothing;

    select id into default_part_id
    from public.part
    where lower(name) = lower(new.name)
        and lower(transposition) = lower(new.transposition);

    insert into public.part_instrument (part_id, instrument_id)
    values (default_part_id, new.id)
    on conflict do nothing;

    return new;
end;
$$;

revoke execute on function private.create_default_part() from public, anon, authenticated;

create trigger instrument_create_default_part after insert on instrument
    for each row execute procedure private.create_default_part();

insert into part (name, transposition)
select name, transposition from instrument
on conflict do nothing;

insert into part_instrument (part_id, instrument_id)
select part.id, instrument.id
from instrument
join part on lower(part.name) = lower(instrument.name)
    and lower(part.transposition) = lower(instrument.transposition)
on conflict do nothing;

insert into part (name, transposition, for_whole_transposition) values
    ('in B Stimmung', 'B', true),
    ('in C Stimmung', 'C', true),
    ('in Es Stimmung', 'Es', true),
    ('in F Stimmung', 'F', true);

create view instrument_part with (security_invoker = true) as
select part_id, instrument_id
from part_instrument
union
select part.id, instrument.id
from part
join instrument on lower(instrument.transposition) = lower(part.transposition)
where part.for_whole_transposition
    and part.transposition <> '';
