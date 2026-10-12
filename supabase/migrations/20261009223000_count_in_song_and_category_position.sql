alter table count_in drop constraint count_in_name_key;
alter table count_in add column song_id bigint not null references song (id) on delete cascade;
alter table count_in add constraint count_in_song_id_name_key unique (song_id, name);

alter table category add column position integer not null;
