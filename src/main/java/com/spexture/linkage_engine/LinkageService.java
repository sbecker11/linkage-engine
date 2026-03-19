package com.spexture.linkage_engine;

import java.util.ArrayList;
import java.util.List;

import org.springframework.ai.chat.model.ChatModel;
import org.springframework.stereotype.Service;

@Service
public class LinkageService implements LinkageResolver {

    private final ChatModel chatModel;
    private final LinkageRecordStore linkageRecordStore;

    public LinkageService(ChatModel chatModel, LinkageRecordStore linkageRecordStore) {
        this.chatModel = chatModel;
        this.linkageRecordStore = linkageRecordStore;
    }

    @Override
    public LinkageResolveResponse resolve(LinkageResolveRequest request) {
        List<String> rulesTriggered = new ArrayList<>();
        rulesTriggered.add("deterministic_name_match");
        if (request.approxYear() != null) {
            rulesTriggered.add("year_window_filter");
        }
        if (!isBlank(request.location())) {
            rulesTriggered.add("location_filter");
        }

        int totalCandidates = linkageRecordStore.countAllRecords();
        List<CandidateRecord> deterministicMatches = linkageRecordStore.findDeterministicCandidates(request);

        String semanticSummary = chatModel.call(buildPrompt(request, deterministicMatches));
        double confidenceScore = computeConfidenceScore(deterministicMatches.size(), request);

        List<String> reasons = new ArrayList<>();
        reasons.add("Deterministic SQL filtering reduced records from " + totalCandidates + " to " + deterministicMatches.size() + ".");
        if (request.approxYear() != null) {
            reasons.add("Applied approxYear window of +/-2 years.");
        }
        if (!isBlank(request.location())) {
            reasons.add("Applied exact location filter before semantic ranking.");
        }

        return new LinkageResolveResponse(
            "deterministic SQL-style narrowing followed by probabilistic semantic ranking",
            totalCandidates,
            deterministicMatches.size(),
            deterministicMatches,
            confidenceScore,
            reasons,
            rulesTriggered,
            semanticSummary
        );
    }

    private String buildPrompt(LinkageResolveRequest request, List<CandidateRecord> matches) {
        String header = "You are a linkage resolver. Rank the candidate records and provide a confidence-oriented summary.";
        String query = "Query person: " + request.givenName() + " " + request.familyName()
            + ", approxYear=" + request.approxYear() + ", location=" + request.location() + ".";
        String candidates = "Deterministic candidates: " + matches;
        String instruction = "Explain likely best matches and why in plain text.";
        return String.join(" ", header, query, candidates, instruction);
    }

    private double computeConfidenceScore(int deterministicMatches, LinkageResolveRequest request) {
        if (deterministicMatches == 0) {
            return 0.15;
        }
        double score = 0.45 + Math.min(0.3, deterministicMatches * 0.15);
        if (request.approxYear() != null) {
            score += 0.1;
        }
        if (!isBlank(request.location())) {
            score += 0.1;
        }
        return Math.min(0.95, score);
    }

    private boolean isBlank(String value) {
        return value == null || value.isBlank();
    }
}
