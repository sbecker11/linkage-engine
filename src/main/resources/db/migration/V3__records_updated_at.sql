-- Add updated_at to records for delta reindex support.
alter table records add column if not exists updated_at timestamp not null default current_timestamp;
