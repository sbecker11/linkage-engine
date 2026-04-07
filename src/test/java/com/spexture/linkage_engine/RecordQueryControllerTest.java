package com.spexture.linkage_engine;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class RecordQueryControllerTest {

    private static final List<LinkageRecord> RECORDS = List.of(
        new LinkageRecord("R-1001", "John",  "Smith", 1850, "Boston",         null),
        new LinkageRecord("R-1002", "John",  "Smith", 1852, "San Francisco",  null),
        new LinkageRecord("R-1003", "Jon",   "Smyth", 1851, "Boston",         null),
        new LinkageRecord("R-1004", "Mary",  "Smith", 1850, "Boston",         null)
    );

    @Test
    void listAllReturnsAllRecords() throws Exception {
        LinkageRecordStore store = mock(LinkageRecordStore.class);
        when(store.findAll()).thenReturn(RECORDS);

        MockMvc mockMvc = MockMvcBuilders
            .standaloneSetup(new RecordQueryController(store))
            .build();

        mockMvc.perform(get("/v1/records"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.length()").value(4))
            .andExpect(jsonPath("$[0].recordId").value("R-1001"))
            .andExpect(jsonPath("$[0].givenName").value("John"))
            .andExpect(jsonPath("$[0].familyName").value("Smith"))
            .andExpect(jsonPath("$[0].year").value(1850))
            .andExpect(jsonPath("$[0].location").value("Boston"));
    }

    @Test
    void listAllReturnsEmptyArrayWhenNoRecords() throws Exception {
        LinkageRecordStore store = mock(LinkageRecordStore.class);
        when(store.findAll()).thenReturn(List.of());

        MockMvc mockMvc = MockMvcBuilders
            .standaloneSetup(new RecordQueryController(store))
            .build();

        mockMvc.perform(get("/v1/records"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.length()").value(0));
    }
}
