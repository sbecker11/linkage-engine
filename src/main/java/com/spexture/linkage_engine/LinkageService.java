package com.spexture.linkage_engine;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

import org.springframework.ai.chat.model.ChatModel;
import org.springframework.stereotype.Service;

@Service
public class LinkageService implements LinkageResolver {

    private static final List<CandidateRecord> SAMPLE_RECORDS = List.of(
        new CandidateRecord("R-1001", "John", "Smith", 1850, "Boston"),
        new CandidateRecord("R-1002", "John", "Smith", 1852, "San Francisco"),
        new CandidateRecord("R-1003", "Jon", "Smyth", 1851, "Boston"),
        new CandidateRecord("R-1004", "Mary", "Smith", 1850, "Boston")
    );

    private final ChatModel chatModel;

    public LinkageService(ChatModel chatModel) {
        this.chatModel = chatModel;
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

        List<CandidateRecord> deterministicMatches = SAMPLE_RECORDS.stream()
            .filter(r -> equalsIgnoreCase(r.givenName(), request.givenName())
                || soundsLike(r.givenName(), request.givenName()))
            .filter(r -> equalsIgnoreCase(r.familyName(), request.familyName())
                || soundsLike(r.familyName(), request.familyName()))
            .filter(r -> request.approxYear() == null || Math.abs(r.year() - request.approxYear()) <= 2)
            .filter(r -> isBlank(request.location()) || equalsIgnoreCase(r.location(), request.location()))
            .toList();

        String semanticSummary = chatModel.call(buildPrompt(request, deterministicMatches));
        double confidenceScore = computeConfidenceScore(deterministicMatches.size(), request);

        List<String> reasons = new ArrayList<>();
        reasons.add("Deterministic filtering reduced records from " + SAMPLE_RECORDS.size() + " to " + deterministicMatches.size() + ".");
        if (request.approxYear() != null) {
            reasons.add("Applied approxYear window of +/-2 years.");
        }
        if (!isBlank(request.location())) {
            reasons.add("Applied exact location filter before semantic ranking.");
        }

        return new LinkageResolveResponse(
            "deterministic SQL-style narrowing followed by probabilistic semantic ranking",
            SAMPLE_RECORDS.size(),
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

    private boolean equalsIgnoreCase(String left, String right) {
        return left != null && right != null && left.equalsIgnoreCase(right);
    }

    private boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    private boolean soundsLike(String left, String right) {
        if (left == null || right == null) {
            return false;
        }
        String l = left.toLowerCase(Locale.ROOT);
        String r = right.toLowerCase(Locale.ROOT);
        return normalizePhonetic(l).equals(normalizePhonetic(r));
    }

    private String normalizePhonetic(String value) {
        return value.replace("ph", "f").replace("y", "i").replaceAll("[^a-z]", "");
    }
}
