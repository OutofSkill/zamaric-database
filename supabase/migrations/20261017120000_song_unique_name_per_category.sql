alter table song add constraint song_category_id_name_key unique (category_id, name);
