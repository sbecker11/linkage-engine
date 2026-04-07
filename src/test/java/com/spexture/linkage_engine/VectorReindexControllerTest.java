package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

@ExtendWith(MockitoExtension.class)
class VectorReindexControllerTest {

    private static final List<ReindexRecord> TWO_RECORDS = List.of(
        new ReindexRecord("R-1", "John", "Smith", 1850, "Boston", "seed", null),
        new ReindexRecord("R-2", "Mary", "Jones", 1851, "Philadelphia", "seed", null)
    );

    private VectorReindexController controller(EmbeddingModel em, RecordEmbeddingStore store,
                                                LinkageRecordStore recordStore) {
        DataCleansingService cleansing = new DataCleansingService(List.of());
        return new VectorReindexController(em, store, recordStore, cleansing, "bedrock-titan");
    }

    @Test
    void returns409WhenEmbeddingModelAbsent() throws Exception {
        LinkageRecordStore recordStore = mock(LinkageRecordStore.class);
        MockMvc mockMvc = MockMvcBuilders.standaloneSetup(
            controller(null, null, recordStore)).build();

        mockMvc.perform(put("/v1/vectors/reindex"))
            .andExpect(status().isConflict())
            .andExpect(jsonPath("$.errors[0]").value("SPRING_AI_MODEL_EMBEDDING not configured"));
    }

    @Test
    void reindexesAllRecordsWhenNoSinceParam() throws Exception {
        EmbeddingModel em = mock(EmbeddingModel.class);
        RecordEmbeddingStore store = mock(RecordEmbeddingStore.class);
        LinkageRecordStore recordStore = mock(LinkageRecordStore.class);

        when(em.embed(any(Document.class))).thenReturn(new float[]{0.1f, 0.2f});
        when(recordStore.findSince(null)).thenReturn(TWO_RECORDS);

        MockMvc mockMvc = MockMvcBuilders.standaloneSetup(
            controller(em, store, recordStore)).build();

        mockMvc.perform(put("/v1/vectors/reindex"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.recordsProcessed").value(2))
            .andExpect(jsonPath("$.chunksWritten").value(2))
            .andExpect(jsonPath("$.errors").isEmpty());
    }

    @Test
    void virtualThreadNamesContainRecordId() throws Exception {
        EmbeddingModel em = mock(EmbeddingModel.class);
        RecordEmbeddingStore store = mock(RecordEmbeddingStore.class);
        LinkageRecordStore recordStore = mock(LinkageRecordStore.class);

        AtomicReference<String> capturedThread = new AtomicReference<>();
        when(em.embed(any(Document.class))).thenAnswer(inv -> {
            capturedThread.set(Thread.currentThread().getName());
            return new float[]{0.1f};
        });
        when(recordStore.findSince(null)).thenReturn(List.of(
            new ReindexRecord("R-VT-1", "Ann", "Lee", 1850, "Boston", "seed", null)
        ));

        MockMvc mockMvc = MockMvcBuilders.standaloneSetup(
            controller(em, store, recordStore)).build();

        mockMvc.perform(put("/v1/vectors/reindex"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.chunksWritten").value(1));

        // Virtual thread name is set to "reindex-{recordId}"
        assertThat(capturedThread.get()).contains("reindex-R-VT-1");
    }

    @Test
    void partialFailurePopulatesErrorsList() throws Exception {
        EmbeddingModel em = mock(EmbeddingModel.class);
        RecordEmbeddingStore store = mock(RecordEmbeddingStore.class);
        LinkageRecordStore recordStore = mock(LinkageRecordStore.class);

        when(recordStore.findSince(null)).thenReturn(TWO_RECORDS);
        when(em.embed(any(Document.class)))
            .thenReturn(new float[]{0.1f})                          // R-1 succeeds
            .thenThrow(new RuntimeException("Bedrock throttled"));  // R-2 fails

        MockMvc mockMvc = MockMvcBuilders.standaloneSetup(
            controller(em, store, recordStore)).build();

        mockMvc.perform(put("/v1/vectors/reindex"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.recordsProcessed").value(2))
            .andExpect(jsonPath("$.chunksWritten").value(1))
            .andExpect(jsonPath("$.errors.length()").value(1));
    }

    @Test
    void returns400ForInvalidSinceFormat() throws Exception {
        EmbeddingModel em = mock(EmbeddingModel.class);
        RecordEmbeddingStore store = mock(RecordEmbeddingStore.class);
        LinkageRecordStore recordStore = mock(LinkageRecordStore.class);

        MockMvc mockMvc = MockMvcBuilders.standaloneSetup(
            controller(em, store, recordStore)).build();

        mockMvc.perform(put("/v1/vectors/reindex").param("since", "not-a-date"))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.errors[0]").value(org.hamcrest.Matchers.containsString("ISO-8601")));
    }
}
