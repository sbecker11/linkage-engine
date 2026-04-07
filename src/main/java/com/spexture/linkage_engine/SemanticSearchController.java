package com.spexture.linkage_engine;

import java.util.Collections;
import java.util.List;
import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/v1/search")
public class SemanticSearchController {

    private static final Logger log = LoggerFactory.getLogger(SemanticSearchController.class);
    private static final int SNIPPET_LENGTH = 200;

    private final EmbeddingModel embeddingModel;
    private final RecordEmbeddingStore recordEmbeddingStore;
    private final LinkageRecordStore linkageRecordStore;

    @Autowired
    public SemanticSearchController(
        @Autowired(required = false) EmbeddingModel embeddingModel,
        @Autowired(required = false) RecordEmbeddingStore recordEmbeddingStore,
        LinkageRecordStore linkageRecordStore
    ) {
        this.embeddingModel = embeddingModel;
        this.recordEmbeddingStore = recordEmbeddingStore;
        this.linkageRecordStore = linkageRecordStore;
    }

    @GetMapping("/semantic")
    public ResponseEntity<SemanticSearchResponse> search(
        @RequestParam(name = "q") String q,
        @RequestParam(name = "maxResults", defaultValue = "5") int maxResults,
        @RequestParam(name = "minScore", defaultValue = "0.75") double minScore
    ) {
        if (embeddingModel == null || recordEmbeddingStore == null) {
            log.debug("[semantic-search] EmbeddingModel or store absent — local profile short-circuit");
            return ResponseEntity.ok(new SemanticSearchResponse(Collections.emptyList(), true, 0));
        }

        float[] queryVector = embeddingModel.embed(new Document(q));

        // Fetch all record IDs to score against
        RecordSearchRequest broadSearch = new RecordSearchRequest(null, null, null, null, q);
        List<CandidateRecord> candidates = linkageRecordStore.search(broadSearch);
        List<String> ids = candidates.stream().map(CandidateRecord::recordId).toList();

        if (ids.isEmpty()) {
            return ResponseEntity.ok(new SemanticSearchResponse(Collections.emptyList(), false, 0));
        }

        Map<String, Double> similarities = recordEmbeddingStore.cosineSimilarityAmong(ids, queryVector);

        List<SemanticSearchResult> results = similarities.entrySet().stream()
            .filter(e -> e.getValue() >= minScore)
            .sorted(Map.Entry.<String, Double>comparingByValue().reversed())
            .limit(maxResults)
            .map(e -> {
                CandidateRecord rec = candidates.stream()
                    .filter(c -> c.recordId().equals(e.getKey()))
                    .findFirst().orElse(null);
                String snippet = rec == null ? "" : buildSnippet(rec);
                Map<String, Object> meta = rec == null ? Map.of() : Map.of(
                    "givenName", rec.givenName(),
                    "familyName", rec.familyName(),
                    "year", rec.year() == null ? "" : rec.year(),
                    "location", rec.location() == null ? "" : rec.location()
                );
                return new SemanticSearchResult(e.getKey(), e.getValue(), snippet, meta);
            })
            .toList();

        log.info("[semantic-search] q='{}' candidates={} above_threshold={}", q, ids.size(), results.size());
        return ResponseEntity.ok(new SemanticSearchResponse(results, false, results.size()));
    }

    private String buildSnippet(CandidateRecord rec) {
        String full = rec.givenName() + " " + rec.familyName()
            + (rec.year() != null ? ", " + rec.year() : "")
            + (rec.location() != null ? ", " + rec.location() : "");
        return full.length() > SNIPPET_LENGTH ? full.substring(0, SNIPPET_LENGTH) : full;
    }
}
