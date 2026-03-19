package com.spexture.linkage_engine;

import java.util.List;
import java.util.Locale;
import java.util.Map;

import org.springframework.ai.chat.model.ChatModel;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

record LinkageResolveRequest(String givenName, String familyName, Integer approxYear, String location) {}

record CandidateRecord(String recordId, String givenName, String familyName, Integer year, String location) {}

record LinkageResolveResponse(
    String strategy,
    int totalCandidates,
    int deterministicMatches,
    List<CandidateRecord> candidates,
    String semanticSummary
) {}

@RestController
@RequestMapping("/v1/linkage")
public class LinkageController {

    private static final List<CandidateRecord> SAMPLE_RECORDS = List.of(
        new CandidateRecord("R-1001", "John", "Smith", 1850, "Boston"),
        new CandidateRecord("R-1002", "John", "Smith", 1852, "San Francisco"),
        new CandidateRecord("R-1003", "Jon", "Smyth", 1851, "Boston"),
        new CandidateRecord("R-1004", "Mary", "Smith", 1850, "Boston")
    );

    private final ChatModel chatModel;

    public LinkageController(ChatModel chatModel) {
        this.chatModel = chatModel;
    }

    @PostMapping("/resolve")
    ResponseEntity<?> resolve(@RequestBody LinkageResolveRequest request) {
        if (request == null || isBlank(request.givenName()) || isBlank(request.familyName())) {
            return ResponseEntity.badRequest().body(Map.of(
                "error", "givenName and familyName are required."
            ));
        }

        List<CandidateRecord> deterministicMatches = SAMPLE_RECORDS.stream()
            .filter(r -> equalsIgnoreCase(r.givenName(), request.givenName())
                || soundsLike(r.givenName(), request.givenName()))
            .filter(r -> equalsIgnoreCase(r.familyName(), request.familyName())
                || soundsLike(r.familyName(), request.familyName()))
            .filter(r -> request.approxYear() == null || Math.abs(r.year() - request.approxYear()) <= 2)
            .filter(r -> isBlank(request.location()) || equalsIgnoreCase(r.location(), request.location()))
            .toList();

        try {
            String semanticSummary = chatModel.call(buildPrompt(request, deterministicMatches));
            return ResponseEntity.ok(new LinkageResolveResponse(
                "deterministic SQL-style narrowing followed by probabilistic semantic ranking",
                SAMPLE_RECORDS.size(),
                deterministicMatches.size(),
                deterministicMatches,
                semanticSummary
            ));
        } catch (Exception ex) {
            return ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(Map.of(
                "error", "Unable to score linkage candidates with model."
            ));
        }
    }

    private String buildPrompt(LinkageResolveRequest request, List<CandidateRecord> matches) {
        String header = "You are a linkage resolver. Rank the candidate records and provide a confidence-oriented summary.";
        String query = "Query person: " + request.givenName() + " " + request.familyName()
            + ", approxYear=" + request.approxYear() + ", location=" + request.location() + ".";
        String candidates = "Deterministic candidates: " + matches;
        String instruction = "Explain likely best matches and why in plain text.";
        return String.join(" ", header, query, candidates, instruction);
    }

    private boolean equalsIgnoreCase(String left, String right) {
        return left != null && right != null && left.equalsIgnoreCase(right);
    }

    private boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    // Tiny phonetic-style fallback for seed data (keeps this endpoint deterministic without DB dependencies).
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
