create extension if not exists vector;

create table if not exists records (
    record_id varchar(64) primary key,
    given_name varchar(120) not null,
    family_name varchar(120) not null,
    event_year integer,
    location varchar(200),
    source text,
    created_at timestamp not null default current_timestamp
);

create table if not exists record_embeddings (
    record_id varchar(64) primary key references records(record_id) on delete cascade,
    embedding vector(1536),
    model_id varchar(120) not null,
    updated_at timestamp not null default current_timestamp
);

create index if not exists idx_records_family_given on records (lower(family_name), lower(given_name));
create index if not exists idx_records_event_year on records (event_year);
create index if not exists idx_records_location on records (lower(location));

insert into records (record_id, given_name, family_name, event_year, location, source)
values
    ('R-1001', 'John', 'Smith', 1850, 'Boston', 'seed'),
    ('R-1002', 'John', 'Smith', 1852, 'San Francisco', 'seed'),
    ('R-1003', 'Jon', 'Smyth', 1851, 'Boston', 'seed'),
    ('R-1004', 'Mary', 'Smith', 1850, 'Boston', 'seed')
on conflict (record_id) do nothing;
