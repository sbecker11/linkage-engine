package com.spexture.linkage_engine;

import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;

public class RecordIngestService implements RecordIngestPort {

    private final LinkageRecordMutator recordMutator;
    private final EmbeddingModel embeddingModel;
    private final RecordEmbeddingStore recordEmbeddingStore;
    private final String embeddingModelId;

    public RecordIngestService(
        LinkageRecordMutator recordMutator,
        EmbeddingModel embeddingModel,
        RecordEmbeddingStore recordEmbeddingStore,
        String embeddingModelId
    ) {
        this.recordMutator = recordMutator;
        this.embeddingModel = embeddingModel;
        this.recordEmbeddingStore = recordEmbeddingStore;
        this.embeddingModelId = embeddingModelId;
    }

    @Override
    public void ingest(RecordIngestRequest request) {
        recordMutator.upsertRecord(request);
        if (!Boolean.TRUE.equals(request.computeEmbedding())) {
            return;
        }
        if (embeddingModel == null || recordEmbeddingStore == null) {
            return;
        }
        String text = LinkageEmbeddingText.toEmbeddingText(
            request.givenName(),
            request.familyName(),
            request.eventYear(),
            request.location()
        );
        float[] vector = embeddingModel.embed(new Document(text));
        recordEmbeddingStore.upsertEmbedding(request.recordId(), vector, embeddingModelId);
    }
}
