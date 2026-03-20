package com.spexture.linkage_engine;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import jakarta.validation.Valid;

/**
 * Registered only via {@link RecordIngestConfiguration} (excluded from {@link LinkageEngineApplication} component scan).
 */
@RestController
@RequestMapping("/v1/records")
public class RecordIngestController {

    private final RecordIngestPort recordIngestPort;

    public RecordIngestController(RecordIngestPort recordIngestPort) {
        this.recordIngestPort = recordIngestPort;
    }

    @PostMapping
    ResponseEntity<Void> ingest(@Valid @RequestBody RecordIngestRequest request) {
        recordIngestPort.ingest(request);
        return ResponseEntity.noContent().build();
    }
}
