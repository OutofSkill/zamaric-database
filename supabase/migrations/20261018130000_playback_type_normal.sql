update playback set type = 'Normal' where type is null;
alter table playback alter column type set default 'Normal';
alter table playback alter column type set not null;
drop index playback_song_id_type_index;
alter table playback add constraint playback_song_id_type_key unique (song_id, type);
