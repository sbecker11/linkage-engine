package com.spexture.linkage_engine;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/v1/spatial")
public class SpatialController {

    private final ConflictResolver conflictResolver;

    public SpatialController(ConflictResolver conflictResolver) {
        this.conflictResolver = conflictResolver;
    }

    @PostMapping("/temporal-overlap")
    ResponseEntity<SpatioTemporalResponse> check(@RequestBody SpatioTemporalRequest request) {
        return ResponseEntity.ok(conflictResolver.resolve(request));
    }
}
