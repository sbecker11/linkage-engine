package com.spexture.linkage_engine;

import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

class LinkageRecordWriteRepositoryTest {

    @Test
    void upsertRecordInvokesJdbcUpdate() {
        JdbcTemplate jdbcTemplate = mock(JdbcTemplate.class);
        LinkageRecordWriteRepository repository = new LinkageRecordWriteRepository(jdbcTemplate);
        RecordIngestRequest request = new RecordIngestRequest(
            "R-x", "Ann", "Lee", 1920, "NYC", "unit-test", null, Boolean.FALSE
        );

        repository.upsertRecord(request);

        verify(jdbcTemplate).update(
            contains("insert into records"),
            eq("R-x"),
            eq("Ann"),
            eq("Lee"),
            eq(1920),
            eq("NYC"),
            eq("unit-test")
        );
    }
}
