package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.model.ChatModel;

class SemanticSummaryServiceTest {

    private static final RecordSearchRequest QUERY =
        new RecordSearchRequest("John", "Smith", 1850, "Boston", null);

    private static final List<CandidateRecord> CANDIDATES = List.of(
        new CandidateRecord("R-1001", "John", "Smith", 1850, "Boston"),
        new CandidateRecord("R-1002", "John", "Smith", 1852, "San Francisco")
    );

    private static final List<CandidateScore> SCORES = List.of(
        new CandidateScore("R-1001", 0.91),
        new CandidateScore("R-1002", 0.72)
    );

    @Test
    void callsChatModelWhenEnabledAndAvailable() {
        ChatModel chatModel = mock(ChatModel.class);
        when(chatModel.call(anyString())).thenReturn("Best match is R-1001.");

        SemanticSummaryService service = new SemanticSummaryService(chatModel, true);
        SemanticSummaryService.SummaryResult result = service.summarize(QUERY, CANDIDATES, SCORES);

        assertThat(result.llmUsed()).isTrue();
        assertThat(result.summary()).isEqualTo("Best match is R-1001.");
    }

    @Test
    void promptContainsCandidateData() {
        SemanticSummaryService service = new SemanticSummaryService(null, true);
        String prompt = service.buildPrompt(QUERY, CANDIDATES, SCORES);

        assertThat(prompt).contains("R-1001");
        assertThat(prompt).contains("R-1002");
        assertThat(prompt).contains("John");
        assertThat(prompt).contains("Smith");
        assertThat(prompt).contains("1850");
        assertThat(prompt).contains("Boston");
        assertThat(prompt).contains("0.910");
        assertThat(prompt).contains("0.720");
    }

    @Test
    void fallsBackToDeterministicWhenLlmDisabled() {
        ChatModel chatModel = mock(ChatModel.class);
        SemanticSummaryService service = new SemanticSummaryService(chatModel, false);
        SemanticSummaryService.SummaryResult result = service.summarize(QUERY, CANDIDATES, SCORES);

        assertThat(result.llmUsed()).isFalse();
        assertThat(result.summary()).contains("R-1001");
        verify(chatModel, never()).call(anyString());
    }

    @Test
    void fallsBackToDeterministicWhenNoChatModel() {
        SemanticSummaryService service = new SemanticSummaryService(null, true);
        SemanticSummaryService.SummaryResult result = service.summarize(QUERY, CANDIDATES, SCORES);

        assertThat(result.llmUsed()).isFalse();
        assertThat(result.summary()).contains("R-1001");
    }

    @Test
    void fallsBackToDeterministicWhenChatModelThrows() {
        ChatModel chatModel = mock(ChatModel.class);
        when(chatModel.call(anyString())).thenThrow(new RuntimeException("bedrock error"));

        SemanticSummaryService service = new SemanticSummaryService(chatModel, true);
        SemanticSummaryService.SummaryResult result = service.summarize(QUERY, CANDIDATES, SCORES);

        assertThat(result.llmUsed()).isFalse();
        assertThat(result.summary()).contains("R-1001");
    }

    @Test
    void deterministicSummaryForEmptyCandidates() {
        SemanticSummaryService service = new SemanticSummaryService(null, false);
        String summary = service.buildDeterministicSummary(List.of());
        assertThat(summary).isEqualTo("No candidates found.");
    }
}
