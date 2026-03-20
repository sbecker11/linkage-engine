-- Titan Embed Text v2 uses 1024 dimensions; replace legacy 1536 placeholder column.
drop table if exists record_embeddings;

create table record_embeddings (
    record_id varchar(64) primary key references records(record_id) on delete cascade,
    embedding vector(1024) not null,
    model_id varchar(120) not null,
    updated_at timestamp not null default current_timestamp
);
