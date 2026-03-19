package com.spexture.linkage_engine;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.model.ChatModel;

import static org.mockito.Mockito.mock;

class LinkageServiceTest {

    @Test
    void resolveReturnsStructuredResponse() {
        ChatModel chatModel = mock(ChatModel.class);
        LinkageRecordStore repository = mock(LinkageRecordStore.class);
        when(chatModel.call(anyString())).thenReturn("Likely match: R-1001.");
        when(repository.countAllRecords()).thenReturn(4);
        when(repository.findDeterministicCandidates(any())).thenReturn(List.of(
            new CandidateRecord("R-1001", "John", "Smith", 1850, "Boston")
        ));
        LinkageService service = new LinkageService(chatModel, repository);

        LinkageResolveResponse response = service.resolve(
            new LinkageResolveRequest("John", "Smith", 1851, "Boston")
        );

        assertEquals(4, response.totalCandidates());
        assertEquals(1, response.deterministicMatches());
        assertEquals("R-1001", response.candidates().get(0).recordId());
        assertTrue(response.confidenceScore() > 0.0);
        assertFalse(response.reasons().isEmpty());
        assertFalse(response.rulesTriggered().isEmpty());
        assertEquals("Likely match: R-1001.", response.semanticSummary());
    }
}
