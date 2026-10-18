alter table letter drop constraint letter_playback_id_name_key;
alter table letter add constraint letter_playback_id_position_ms_key unique (playback_id, position_ms);
