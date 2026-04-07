package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;

class RecordIngestServiceTest {

    private static final DataCleansingService CLEANSING = new DataCleansingService(List.of(
        new OCRNoiseReducer(),
        new LocationStandardizer()
    ));

    private static RecordIngestService service(LinkageRecordMutator writes, EmbeddingModel embed, RecordEmbeddingStore store) {
        return new RecordIngestService(writes, embed, store, "amazon.titan-embed-text-v2:0", CLEANSING);
    }

    @Test
    void ingestSkipsEmbeddingWhenDisabled() {
        LinkageRecordMutator writes = mock(LinkageRecordMutator.class);
        EmbeddingModel embed = mock(EmbeddingModel.class);
        RecordEmbeddingStore store = mock(RecordEmbeddingStore.class);

        RecordIngestRequest req = new RecordIngestRequest(
            "R-9", "A", "B", 1, "L", "src", null, Boolean.FALSE
        );

        service(writes, embed, store).ingest(req);

        verify(writes).upsertRecord(req);
        verify(embed, never()).embed(any(Document.class));
        verify(store, never()).upsertEmbedding(any(), any(), any());
    }

    @Test
    void ingestWritesEmbeddingWhenEnabled() {
        LinkageRecordMutator writes = mock(LinkageRecordMutator.class);
        EmbeddingModel embed = mock(EmbeddingModel.class);
        RecordEmbeddingStore store = mock(RecordEmbeddingStore.class);
        when(embed.embed(any(Document.class))).thenReturn(new float[1024]);

        RecordIngestRequest req = new RecordIngestRequest(
            "R-9", "A", "B", 1, "L", "src", null, Boolean.TRUE
        );

        service(writes, embed, store).ingest(req);

        verify(writes).upsertRecord(req);
        verify(embed).embed(any(Document.class));
        verify(store).upsertEmbedding(eq("R-9"), any(float[].class), eq("amazon.titan-embed-text-v2:0"));
    }

    @Test
    void ingestSkipsEmbeddingWhenModelAbsent() {
        LinkageRecordMutator writes = mock(LinkageRecordMutator.class);
        RecordEmbeddingStore store = mock(RecordEmbeddingStore.class);

        RecordIngestRequest req = new RecordIngestRequest(
            "R-9", "A", "B", 1, "L", "src", null, Boolean.TRUE
        );

        new RecordIngestService(writes, null, store, "model", CLEANSING).ingest(req);

        verify(writes).upsertRecord(req);
        verify(store, never()).upsertEmbedding(any(), any(), any());
    }

    @Test
    void buildEmbeddingTextUsesCleanedRawContentWhenPresent() {
        RecordIngestService svc = new RecordIngestService(
            mock(LinkageRecordMutator.class), null, null, "model", CLEANSING
        );
        RecordIngestRequest req = new RecordIngestRequest(
            "R-1", "John", "Smith", 1850, "Philly", "src", "John Smith, Philly, 18S0", Boolean.FALSE
        );

        String text = svc.buildEmbeddingText(req);

        assertThat(text).isEqualTo("John Smith, Philadelphia, 1850");
    }

    @Test
    void ingestNoopsWhenMutatorNull() {
        EmbeddingModel embed = mock(EmbeddingModel.class);
        RecordIngestRequest req = new RecordIngestRequest(
            "R-9", "A", "B", 1, "L", "src", null, Boolean.TRUE
        );
        // Should not throw
        new RecordIngestService(null, embed, null, "model", CLEANSING).ingest(req);
        verify(embed, never()).embed(any(Document.class));
    }

    @Test
    void buildEmbeddingTextFallsBackToStructuredFieldsWhenNoRawContent() {
        RecordIngestService svc = new RecordIngestService(
            mock(LinkageRecordMutator.class), null, null, "model", CLEANSING
        );
        RecordIngestRequest req = new RecordIngestRequest(
            "R-1", "John", "Smith", 1850, "Boston", "src", null, Boolean.FALSE
        );

        String text = svc.buildEmbeddingText(req);

        assertThat(text).isEqualTo("givenName=John familyName=Smith year=1850 location=Boston");
    }
}
