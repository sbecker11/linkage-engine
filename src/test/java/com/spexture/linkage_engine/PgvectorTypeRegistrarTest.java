package com.spexture.linkage_engine;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.sql.Connection;
import java.sql.SQLException;

import javax.sql.DataSource;

import org.junit.jupiter.api.Test;
import org.mockito.MockedStatic;
import org.mockito.Mockito;

import com.pgvector.PGvector;

class PgvectorTypeRegistrarTest {

    @Test
    void registerAddsVectorTypeOnConnection() throws SQLException {
        DataSource dataSource = mock(DataSource.class);
        Connection connection = mock(Connection.class);
        when(dataSource.getConnection()).thenReturn(connection);

        try (MockedStatic<PGvector> pg = Mockito.mockStatic(PGvector.class)) {
            new PgvectorTypeRegistrar(dataSource).register();
            pg.verify(() -> PGvector.addVectorType(connection));
        }
    }
}
