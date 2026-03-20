package com.spexture.linkage_engine;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.Collection;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import com.pgvector.PGvector;

@Repository
@ConditionalOnBean(JdbcTemplate.class)
public class RecordEmbeddingRepository implements RecordEmbeddingStore {

    private final JdbcTemplate jdbcTemplate;

    public RecordEmbeddingRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    @Override
    public Map<String, Double> cosineSimilarityAmong(Collection<String> recordIds, float[] queryEmbedding) {
        if (recordIds == null || recordIds.isEmpty()) {
            return Collections.emptyMap();
        }
        String[] idArray = recordIds.toArray(String[]::new);
        PGvector query = new PGvector(queryEmbedding);

        return jdbcTemplate.execute((Connection connection) -> {
            try (PreparedStatement ps = connection.prepareStatement("""
                select record_id, 1 - (embedding <=> ?::vector) as sim
                from record_embeddings
                where record_id = any (?::varchar[])
                order by embedding <=> ?::vector asc
                """)) {
                ps.setObject(1, query);
                ps.setArray(2, connection.createArrayOf("varchar", idArray));
                ps.setObject(3, query);
                Map<String, Double> out = new HashMap<>();
                try (ResultSet rs = ps.executeQuery()) {
                    while (rs.next()) {
                        out.put(rs.getString("record_id"), rs.getDouble("sim"));
                    }
                }
                return out;
            }
        });
    }

    @Override
    public void upsertEmbedding(String recordId, float[] embedding, String modelId) {
        PGvector vec = new PGvector(embedding);
        jdbcTemplate.update(
            """
                insert into record_embeddings (record_id, embedding, model_id)
                values (?, ?::vector, ?)
                on conflict (record_id) do update set
                    embedding = excluded.embedding,
                    model_id = excluded.model_id,
                    updated_at = current_timestamp
                """,
            recordId,
            vec,
            modelId
        );
    }
}
