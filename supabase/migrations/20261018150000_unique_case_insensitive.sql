alter table category drop constraint category_name_key;
create unique index category_lower_name_key on category (lower(name));

alter table level drop constraint level_name_key;
create unique index level_lower_name_key on level (lower(name));

alter table instrument drop constraint instrument_name_transposition_key;
create unique index instrument_lower_name_transposition_key on instrument (lower(name), lower(transposition));

alter table song drop constraint song_category_id_name_key;
create unique index song_category_id_lower_name_key on song (category_id, lower(name));

alter table count_in drop constraint count_in_song_id_name_key;
create unique index count_in_song_id_lower_name_key on count_in (song_id, lower(name));

alter table playback drop constraint playback_song_id_type_key;
create unique index playback_song_id_lower_type_key on playback (song_id, lower(type));
