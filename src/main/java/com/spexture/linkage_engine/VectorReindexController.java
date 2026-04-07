package com.spexture.linkage_engine;

import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/v1/vectors")
public class VectorReindexController {

    private static final Logger log = LoggerFactory.getLogger(VectorReindexController.class);

    private final EmbeddingModel embeddingModel;
    private final RecordEmbeddingStore recordEmbeddingStore;
    private final LinkageRecordStore linkageRecordStore;
    private final DataCleansingService cleansingService;
    private final String embeddingModelId;

    @Autowired
    public VectorReindexController(
        @Autowired(required = false) EmbeddingModel embeddingModel,
        @Autowired(required = false) RecordEmbeddingStore recordEmbeddingStore,
        LinkageRecordStore linkageRecordStore,
        DataCleansingService cleansingService,
        @Value("${spring.ai.bedrock.titan.embedding.model:bedrock-titan}") String embeddingModelId
    ) {
        this.embeddingModel = embeddingModel;
        this.recordEmbeddingStore = recordEmbeddingStore;
        this.linkageRecordStore = linkageRecordStore;
        this.cleansingService = cleansingService;
        this.embeddingModelId = embeddingModelId;
    }

    @PutMapping("/reindex")
    public ResponseEntity<ReindexResponse> reindex(
        @RequestParam(name = "since", required = false) String since
    ) {
        if (embeddingModel == null || recordEmbeddingStore == null) {
            log.warn("[reindex] SPRING_AI_MODEL_EMBEDDING not configured — returning 409");
            return ResponseEntity.status(HttpStatus.CONFLICT)
                .body(new ReindexResponse(0, 0, 0, List.of("SPRING_AI_MODEL_EMBEDDING not configured")));
        }

        Instant sinceInstant = null;
        if (since != null && !since.isBlank()) {
            try {
                sinceInstant = Instant.parse(since);
            } catch (DateTimeParseException e) {
                return ResponseEntity.badRequest()
                    .body(new ReindexResponse(0, 0, 0, List.of("Invalid 'since' format; use ISO-8601 e.g. 2025-01-01T00:00:00Z")));
            }
        }

        List<ReindexRecord> records = linkageRecordStore.findSince(sinceInstant);
        log.info("[reindex] since={} records={}", sinceInstant, records.size());

        long start = System.currentTimeMillis();
        AtomicInteger chunksWritten = new AtomicInteger(0);
        List<String> errors = new ArrayList<>();
        CountDownLatch latch = new CountDownLatch(records.size());

        for (ReindexRecord record : records) {
            Thread.ofVirtual()
                .name("reindex-" + record.recordId())
                .start(() -> {
                    try {
                        String text = buildEmbeddingText(record);
                        float[] vector = embeddingModel.embed(new Document(text));
                        recordEmbeddingStore.upsertEmbedding(record.recordId(), vector, embeddingModelId);
                        chunksWritten.incrementAndGet();
                        log.debug("[reindex] embedded recordId={} thread={}", record.recordId(),
                            Thread.currentThread().getName());
                    } catch (Exception ex) {
                        log.warn("[reindex] failed recordId={}: {}", record.recordId(), ex.getMessage());
                        synchronized (errors) {
                            errors.add(record.recordId() + ": " + ex.getMessage());
                        }
                    } finally {
                        latch.countDown();
                    }
                });
        }

        try {
            latch.await();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            errors.add("Reindex interrupted: " + e.getMessage());
        }

        long durationMs = System.currentTimeMillis() - start;
        log.info("[reindex] done records={} chunks={} errors={} durationMs={}",
            records.size(), chunksWritten.get(), errors.size(), durationMs);

        return ResponseEntity.ok(new ReindexResponse(records.size(), chunksWritten.get(), durationMs, errors));
    }

    private String buildEmbeddingText(ReindexRecord record) {
        if (record.rawContent() != null && !record.rawContent().isBlank()) {
            return cleansingService.cleanse(record.rawContent());
        }
        return LinkageEmbeddingText.toEmbeddingText(
            record.givenName(), record.familyName(), record.eventYear(), record.location()
        );
    }
}
