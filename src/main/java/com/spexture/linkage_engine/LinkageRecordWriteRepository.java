package com.spexture.linkage_engine;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

@Repository
public class LinkageRecordWriteRepository implements LinkageRecordMutator {

    private final JdbcTemplate jdbcTemplate;

    public LinkageRecordWriteRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    @Override
    public void upsertRecord(RecordIngestRequest request) {
        jdbcTemplate.update(
            """
                insert into records (record_id, given_name, family_name, event_year, birth_year, location, source)
                values (?, ?, ?, ?, ?, ?, ?)
                on conflict (record_id) do update set
                    given_name = excluded.given_name,
                    family_name = excluded.family_name,
                    event_year = excluded.event_year,
                    birth_year = excluded.birth_year,
                    location = excluded.location,
                    source = excluded.source
                """,
            request.recordId(),
            request.givenName(),
            request.familyName(),
            request.eventYear(),
            request.birthYear(),
            request.location(),
            request.source()
        );
    }
}
