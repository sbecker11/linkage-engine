-- Add gender column to records table.
-- Values: 'M', 'F', 'U' (unknown). Defaults to 'U' so existing rows are unaffected.
alter table records add column if not exists gender char(1) not null default 'U';

create index if not exists idx_records_gender on records (gender);
