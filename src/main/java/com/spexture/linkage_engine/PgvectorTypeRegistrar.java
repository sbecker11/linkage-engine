package com.spexture.linkage_engine;

import java.sql.Connection;
import java.sql.SQLException;

import javax.sql.DataSource;

import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.stereotype.Component;

import com.pgvector.PGvector;

import jakarta.annotation.PostConstruct;

/**
 * Registers the pgvector type with JDBC so {@link PGvector} binds correctly on {@link org.springframework.jdbc.core.JdbcTemplate} calls.
 */
@Component
@ConditionalOnBean(DataSource.class)
public class PgvectorTypeRegistrar {

    private final DataSource dataSource;

    public PgvectorTypeRegistrar(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @PostConstruct
    public void register() throws SQLException {
        try (Connection connection = dataSource.getConnection()) {
            PGvector.addVectorType(connection);
        }
    }
}
