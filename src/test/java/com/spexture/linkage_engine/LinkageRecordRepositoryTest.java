package com.spexture.linkage_engine;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

class LinkageRecordRepositoryTest {

    private LinkageRecordRepository repository;

    @BeforeEach
    void setUp() {
        DriverManagerDataSource dataSource = new DriverManagerDataSource();
        dataSource.setDriverClassName("org.h2.Driver");
        dataSource.setUrl("jdbc:h2:mem:linkage_repo;MODE=PostgreSQL;DB_CLOSE_DELAY=-1");
        dataSource.setUsername("sa");
        dataSource.setPassword("");

        JdbcTemplate jdbcTemplate = new JdbcTemplate(dataSource);
        jdbcTemplate.execute("drop table if exists records");
        jdbcTemplate.execute("""
            create table records (
                record_id varchar(64) primary key,
                given_name varchar(120) not null,
                family_name varchar(120) not null,
                event_year integer,
                location varchar(200)
            )
            """);
        jdbcTemplate.update("insert into records(record_id,given_name,family_name,event_year,location) values(?,?,?,?,?)",
            "R-1001", "John", "Smith", 1850, "Boston");
        jdbcTemplate.update("insert into records(record_id,given_name,family_name,event_year,location) values(?,?,?,?,?)",
            "R-1002", "John", "Smith", 1852, "San Francisco");
        jdbcTemplate.update("insert into records(record_id,given_name,family_name,event_year,location) values(?,?,?,?,?)",
            "R-1003", "Jon", "Smith", 1851, "Boston");

        repository = new LinkageRecordRepository(jdbcTemplate);
    }

    @Test
    void countAllRecordsReturnsRowCount() {
        assertEquals(3, repository.countAllRecords());
    }

    @Test
    void deterministicCandidatesApplyYearAndLocationFilters() {
        LinkageResolveRequest request = new LinkageResolveRequest("John", "Smith", 1851, "Boston");
        List<CandidateRecord> results = repository.findDeterministicCandidates(request);

        assertEquals(2, results.size());
        assertTrue(results.stream().anyMatch(r -> r.recordId().equals("R-1001")));
        assertTrue(results.stream().anyMatch(r -> r.recordId().equals("R-1003")));
    }

    @Test
    void deterministicCandidatesUseGivenNameNormalization() {
        LinkageResolveRequest request = new LinkageResolveRequest("Jon", "Smith", null, "");
        List<CandidateRecord> results = repository.findDeterministicCandidates(request);

        assertEquals(3, results.size());
    }
}
