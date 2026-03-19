package com.spexture.linkage_engine;

import java.util.List;

import jakarta.validation.constraints.NotBlank;

record LinkageResolveRequest(
    @NotBlank(message = "givenName is required")
    String givenName,
    @NotBlank(message = "familyName is required")
    String familyName,
    Integer approxYear,
    String location
) {}

record CandidateRecord(String recordId, String givenName, String familyName, Integer year, String location) {}

record LinkageResolveResponse(
    String strategy,
    int totalCandidates,
    int deterministicMatches,
    List<CandidateRecord> candidates,
    double confidenceScore,
    List<String> reasons,
    List<String> rulesTriggered,
    String semanticSummary
) {}
