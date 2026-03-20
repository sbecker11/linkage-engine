package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

import java.util.Collections;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

class RecordEmbeddingRepositoryTest {

    @Test
    void cosineSimilarityAmongEmptyIdsReturnsEmptyMap() {
        JdbcTemplate jdbcTemplate = mock(JdbcTemplate.class);
        RecordEmbeddingRepository repository = new RecordEmbeddingRepository(jdbcTemplate);
        assertThat(repository.cosineSimilarityAmong(Collections.emptyList(), new float[1])).isEmpty();
        assertThat(repository.cosineSimilarityAmong(null, new float[1])).isEmpty();
    }

    @Test
    void upsertEmbeddingInvokesJdbcUpdate() {
        JdbcTemplate jdbcTemplate = mock(JdbcTemplate.class);
        RecordEmbeddingRepository repository = new RecordEmbeddingRepository(jdbcTemplate);

        repository.upsertEmbedding("R-1", new float[1024], "amazon.titan-embed-text-v2:0");

        verify(jdbcTemplate).update(
            contains("record_embeddings"),
            eq("R-1"),
            any(),
            eq("amazon.titan-embed-text-v2:0")
        );
    }
}
