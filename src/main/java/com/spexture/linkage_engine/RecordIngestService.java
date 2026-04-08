package com.spexture.linkage_engine;

import io.micrometer.core.annotation.Timed;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;

public class RecordIngestService implements RecordIngestPort {

    private static final Logger log = LoggerFactory.getLogger(RecordIngestService.class);

    private final LinkageRecordMutator recordMutator;
    private final EmbeddingModel embeddingModel;
    private final RecordEmbeddingStore recordEmbeddingStore;
    private final String embeddingModelId;
    private final DataCleansingService cleansingService;

    public RecordIngestService(
        LinkageRecordMutator recordMutator,
        EmbeddingModel embeddingModel,
        RecordEmbeddingStore recordEmbeddingStore,
        String embeddingModelId,
        DataCleansingService cleansingService
    ) {
        this.recordMutator = recordMutator;
        this.embeddingModel = embeddingModel;
        this.recordEmbeddingStore = recordEmbeddingStore;
        this.embeddingModelId = embeddingModelId;
        this.cleansingService = cleansingService;
    }

    @Override
    @Timed(value = "linkage.ingest", description = "Time taken to ingest a single record including embedding")
    public void ingest(RecordIngestRequest request) {
        if (recordMutator == null) {
            return;
        }
        recordMutator.upsertRecord(request);
        if (!Boolean.TRUE.equals(request.computeEmbedding())) {
            return;
        }
        if (embeddingModel == null || recordEmbeddingStore == null) {
            return;
        }
        String textToEmbed = buildEmbeddingText(request);
        log.debug("Embedding text for {}: {}", request.recordId(), textToEmbed);
        float[] vector = embeddingModel.embed(new Document(textToEmbed));
        recordEmbeddingStore.upsertEmbedding(request.recordId(), vector, embeddingModelId);
    }

    /**
     * If {@code rawContent} is provided, cleanse it and use it as the embedding text.
     * Otherwise fall back to the structured fields.
     */
    String buildEmbeddingText(RecordIngestRequest request) {
        if (request.rawContent() != null && !request.rawContent().isBlank()) {
            return cleansingService.cleanse(request.rawContent());
        }
        return LinkageEmbeddingText.toEmbeddingText(
            request.givenName(),
            request.familyName(),
            request.eventYear(),
            request.location()
        );
    }
}
