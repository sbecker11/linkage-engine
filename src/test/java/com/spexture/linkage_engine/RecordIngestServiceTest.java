package com.spexture.linkage_engine;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import org.junit.jupiter.api.Test;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;

class RecordIngestServiceTest {

    @Test
    void ingestSkipsEmbeddingWhenDisabled() {
        LinkageRecordMutator writes = mock(LinkageRecordMutator.class);
        EmbeddingModel embed = mock(EmbeddingModel.class);
        RecordEmbeddingStore store = mock(RecordEmbeddingStore.class);

        RecordIngestRequest req = new RecordIngestRequest(
            "R-9", "A", "B", 1, "L", "src", Boolean.FALSE
        );

        RecordIngestService service = new RecordIngestService(writes, embed, store, "amazon.titan-embed-text-v2:0");
        service.ingest(req);

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
            "R-9", "A", "B", 1, "L", "src", Boolean.TRUE
        );

        RecordIngestService service = new RecordIngestService(writes, embed, store, "amazon.titan-embed-text-v2:0");
        service.ingest(req);

        verify(writes).upsertRecord(req);
        verify(embed).embed(any(Document.class));
        verify(store).upsertEmbedding(eq("R-9"), any(float[].class), eq("amazon.titan-embed-text-v2:0"));
    }
}
