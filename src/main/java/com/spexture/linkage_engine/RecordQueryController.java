package com.spexture.linkage_engine;

import java.util.List;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Read-only record queries. Separate from {@link RecordIngestController} so the
 * read path has no dependency on the ingest configuration or embedding pipeline.
 */
@RestController
@RequestMapping("/v1/records")
public class RecordQueryController {

    private final LinkageRecordStore recordStore;

    public RecordQueryController(LinkageRecordStore recordStore) {
        this.recordStore = recordStore;
    }

    /** Returns all records ordered by record_id. Used by the chord-diagram data pipeline. */
    @GetMapping
    public ResponseEntity<List<LinkageRecord>> listAll() {
        return ResponseEntity.ok(recordStore.findAll());
    }
}
