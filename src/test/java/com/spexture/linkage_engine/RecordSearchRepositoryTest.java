package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

/**
 * H2 in-memory tests for {@link LinkageRecordRepository#search(RecordSearchRequest)}.
 */
class RecordSearchRepositoryTest {

    private LinkageRecordRepository repository;

    @BeforeEach
    void setUp() {
        DriverManagerDataSource ds = new DriverManagerDataSource();
        ds.setDriverClassName("org.h2.Driver");
        ds.setUrl("jdbc:h2:mem:search_test;MODE=PostgreSQL;DB_CLOSE_DELAY=-1");
        ds.setUsername("sa");
        ds.setPassword("");

        JdbcTemplate jdbc = new JdbcTemplate(ds);
        jdbc.execute("drop table if exists records");
        jdbc.execute("""
            create table records (
                record_id varchar(64) primary key,
                given_name varchar(120) not null,
                family_name varchar(120) not null,
                event_year integer,
                location varchar(200),
                source text,
                created_at timestamp default current_timestamp
            )
            """);

        // Seed data with deliberate overlaps
        Object[][] rows = {
            {"R-1001", "John",    "Smith",   1850, "Boston"},
            {"R-1002", "John",    "Smith",   1852, "San Francisco"},
            {"R-1003", "Jon",     "Smith",   1851, "Boston"},
            {"R-1004", "Johnny",  "Smith",   1848, "Boston"},   // partial given name
            {"R-1005", "John",    "Smythe",  1850, "Boston"},   // partial family name
            {"R-1006", "Mary",    "Jones",   1900, "Chicago"},  // different person
            {"R-1007", "John",    "Smith",   1860, "Boston"},   // outside ±5 window from 1850
        };
        for (Object[] r : rows) {
            jdbc.update("insert into records(record_id,given_name,family_name,event_year,location,source) values(?,?,?,?,?,?)",
                r[0], r[1], r[2], r[3], r[4], "test");
        }
        repository = new LinkageRecordRepository(jdbc);
    }

    @Test
    void partialFamilyNameMatchReturnsResults() {
        // "Smit" should match "Smith" and "Smythe"
        RecordSearchRequest req = new RecordSearchRequest("John", "Smit", null, null, null);
        List<CandidateRecord> results = repository.search(req);
        assertThat(results).isNotEmpty();
        assertThat(results).allMatch(r -> r.familyName().toLowerCase().contains("smit"));
    }

    @Test
    void partialGivenNameMatchReturnsResults() {
        // "Joh" should match "John" and "Johnny"
        RecordSearchRequest req = new RecordSearchRequest("Joh", "Smith", null, null, null);
        List<CandidateRecord> results = repository.search(req);
        assertThat(results).extracting(CandidateRecord::givenName)
            .allMatch(n -> n.toLowerCase().contains("joh"));
        assertThat(results.stream().map(CandidateRecord::recordId))
            .contains("R-1001", "R-1004");
    }

    @Test
    void yearWindowFiveTolerance() {
        // approxYear=1850, ±5 → 1845–1855; R-1007 (1860) should be excluded
        // "John" partial matches "John" (R-1001, R-1002) and "Johnny" (R-1004), but NOT "Jon" (R-1003)
        RecordSearchRequest req = new RecordSearchRequest("John", "Smith", 1850, null, null);
        List<CandidateRecord> results = repository.search(req);
        assertThat(results).extracting(CandidateRecord::recordId)
            .contains("R-1001", "R-1002", "R-1004")
            .doesNotContain("R-1007");
    }

    @Test
    void locationPartialMatchFilters() {
        RecordSearchRequest req = new RecordSearchRequest("John", "Smith", null, "Boston", null);
        List<CandidateRecord> results = repository.search(req);
        assertThat(results).allMatch(r -> r.location() != null && r.location().toLowerCase().contains("boston"));
    }

    @Test
    void noYearNoLocationReturnsAllNameMatches() {
        RecordSearchRequest req = new RecordSearchRequest("John", "Smith", null, null, null);
        List<CandidateRecord> results = repository.search(req);
        // R-1001, R-1002, R-1007 are exact "John Smith"; R-1004 "Johnny Smith" also matches partial
        assertThat(results).hasSizeGreaterThanOrEqualTo(3);
    }

    @Test
    void limitIsAtMostTwenty() {
        // Insert 25 extra records to verify limit
        JdbcTemplate jdbc = new JdbcTemplate(new DriverManagerDataSource(
            "jdbc:h2:mem:search_test;MODE=PostgreSQL;DB_CLOSE_DELAY=-1", "sa", ""));
        for (int i = 0; i < 25; i++) {
            jdbc.update("insert into records(record_id,given_name,family_name,event_year,location,source) values(?,?,?,?,?,?)",
                "R-BULK-" + i, "John", "Smith", 1850 + i, "Boston", "test");
        }
        RecordSearchRequest req = new RecordSearchRequest("John", "Smith", null, null, null);
        List<CandidateRecord> results = repository.search(req);
        assertThat(results).hasSizeLessThanOrEqualTo(20);
    }

    @Test
    void differentPersonNotReturned() {
        RecordSearchRequest req = new RecordSearchRequest("John", "Smith", 1850, "Boston", null);
        List<CandidateRecord> results = repository.search(req);
        assertThat(results).extracting(CandidateRecord::recordId).doesNotContain("R-1006");
    }
}
