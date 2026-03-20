package com.spexture.linkage_engine;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;

import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

@Repository
@ConditionalOnBean(JdbcTemplate.class)
public class LinkageRecordRepository implements LinkageRecordStore {

    private final JdbcTemplate jdbcTemplate;

    public LinkageRecordRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    @Override
    public int countAllRecords() {
        Integer count = jdbcTemplate.queryForObject("select count(*) from records", Integer.class);
        return count == null ? 0 : count;
    }

    @Override
    public List<CandidateRecord> findDeterministicCandidates(LinkageResolveRequest request) {
        String sql = """
            select record_id, given_name, family_name, event_year, location
            from records
            where lower(family_name) = lower(?)
              and (
                    lower(given_name) = lower(?)
                    or lower(given_name) = lower(?)
                  )
              and (? is null or abs(event_year - ?) <= 2)
              and (? is null or ? = '' or lower(location) = lower(?))
            order by event_year asc
            limit 25
            """;

        String normalizedGivenName = normalizeGivenName(request.givenName());
        return jdbcTemplate.query(
            sql,
            CANDIDATE_ROW_MAPPER,
            request.familyName(),
            request.givenName(),
            normalizedGivenName,
            request.approxYear(),
            request.approxYear(),
            request.location(),
            request.location(),
            request.location()
        );
    }

    private String normalizeGivenName(String givenName) {
        if (givenName == null) {
            return null;
        }
        return switch (givenName.toLowerCase()) {
            case "jon" -> "john";
            case "john" -> "jon";
            default -> givenName;
        };
    }

    private static final RowMapper<CandidateRecord> CANDIDATE_ROW_MAPPER = new RowMapper<>() {
        @Override
        public CandidateRecord mapRow(ResultSet rs, int rowNum) throws SQLException {
            return new CandidateRecord(
                rs.getString("record_id"),
                rs.getString("given_name"),
                rs.getString("family_name"),
                rs.getInt("event_year"),
                rs.getString("location")
            );
        }
    };
}
