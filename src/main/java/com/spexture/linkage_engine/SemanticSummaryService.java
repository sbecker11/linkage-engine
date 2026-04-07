package com.spexture.linkage_engine;

import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

/**
 * Generates a narrative summary of ranked linkage candidates.
 * When {@code LINKAGE_SEMANTIC_LLM_ENABLED=false} or no {@link ChatModel} is available,
 * falls back to a deterministic summary string.
 */
@Service
public class SemanticSummaryService {

    private static final Logger log = LoggerFactory.getLogger(SemanticSummaryService.class);

    private final ChatModel chatModel;
    private final boolean semanticLlmEnabled;

    @Autowired
    public SemanticSummaryService(
        @Autowired(required = false) ChatModel chatModel,
        @Value("${linkage.semantic.llm.enabled:true}") boolean semanticLlmEnabled
    ) {
        this.chatModel = chatModel;
        this.semanticLlmEnabled = semanticLlmEnabled;
    }

    /**
     * Produces a summary string. Never throws — falls back to deterministic on any error.
     */
    public SummaryResult summarize(RecordSearchRequest request, List<CandidateRecord> rankedCandidates,
                                   List<CandidateScore> scores) {
        if (!semanticLlmEnabled || chatModel == null) {
            String summary = buildDeterministicSummary(rankedCandidates);
            log.debug("Semantic summary skipped (enabled={}, model={}), using deterministic",
                semanticLlmEnabled, chatModel != null);
            return new SummaryResult(summary, false);
        }

        try {
            String prompt = buildPrompt(request, rankedCandidates, scores);
            String summary = chatModel.call(prompt);
            log.debug("Semantic summary produced via ChatModel ({} chars)", summary.length());
            return new SummaryResult(summary, true);
        } catch (RuntimeException ex) {
            log.warn("ChatModel call failed, falling back to deterministic summary: {}", ex.getMessage());
            return new SummaryResult(buildDeterministicSummary(rankedCandidates), false);
        }
    }

    String buildPrompt(RecordSearchRequest request, List<CandidateRecord> candidates,
                       List<CandidateScore> scores) {
        StringBuilder sb = new StringBuilder();
        sb.append("You are a genealogical record linkage resolver. ");
        sb.append("Given the query and ranked candidates below, identify the best match and explain your reasoning.\n\n");
        sb.append("Query: givenName=").append(request.givenName())
          .append(" familyName=").append(request.familyName());
        if (request.approxYear() != null) {
            sb.append(" approxYear=").append(request.approxYear());
        }
        if (request.location() != null && !request.location().isBlank()) {
            sb.append(" location=").append(request.location());
        }
        sb.append("\n\nRanked candidates (recordId | name | year | location | similarity):\n");
        for (int i = 0; i < candidates.size(); i++) {
            CandidateRecord c = candidates.get(i);
            Double sim = i < scores.size() ? scores.get(i).vectorSimilarity() : null;
            sb.append(String.format("  %d. %s | %s %s | %s | %s | %s%n",
                i + 1, c.recordId(), c.givenName(), c.familyName(),
                c.year(), c.location(),
                sim != null ? String.format("%.3f", sim) : "n/a"));
        }
        sb.append("\nProvide a concise confidence-oriented summary in plain text.");
        return sb.toString();
    }

    String buildDeterministicSummary(List<CandidateRecord> candidates) {
        if (candidates.isEmpty()) {
            return "No candidates found.";
        }
        CandidateRecord top = candidates.get(0);
        return "Top deterministic candidate: " + top.recordId()
            + " (" + top.givenName() + " " + top.familyName()
            + ", " + top.year() + ", " + top.location() + ").";
    }

    record SummaryResult(String summary, boolean llmUsed) {}
}
