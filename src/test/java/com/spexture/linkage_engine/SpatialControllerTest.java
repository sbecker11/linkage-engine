package com.spexture.linkage_engine;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

@ExtendWith(MockitoExtension.class)
class SpatialControllerTest {

    private MockMvc mockMvc;

    @Mock
    private ConflictResolver conflictResolver;

    @BeforeEach
    void setUp() {
        mockMvc = MockMvcBuilders.standaloneSetup(new SpatialController(conflictResolver)).build();
    }

    @Test
    void temporalOverlapReturnsPlausibleResponse() throws Exception {
        SpatioTemporalResponse response = new SpatioTemporalResponse(
            true, 1.5, 365.0, 363.5, "railroad_eastern", List.of(), 0, Map.of()
        );
        when(conflictResolver.resolve(any())).thenReturn(response);

        mockMvc.perform(post("/v1/spatial/temporal-overlap")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                    {
                      "from": {"recordId":"R-1","location":"Boston","year":1850},
                      "to":   {"recordId":"R-2","location":"Philadelphia","year":1851}
                    }
                    """))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.plausible").value(true))
            .andExpect(jsonPath("$.transitMode").value("railroad_eastern"))
            .andExpect(jsonPath("$.travelDays").value(1.5))
            .andExpect(jsonPath("$.confidenceAdjustment").value(0));
    }

    @Test
    void temporalOverlapReturnsImplausibleResponse() throws Exception {
        SpatioTemporalResponse response = new SpatioTemporalResponse(
            false, 120.0, 365.0, -(-245.0), "ocean_ship",
            List.of("physical_impossibility"), 50, Map.of("physical_impossibility", 50)
        );
        when(conflictResolver.resolve(any())).thenReturn(response);

        mockMvc.perform(post("/v1/spatial/temporal-overlap")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                    {
                      "from": {"recordId":"R-1","location":"Boston","year":1850},
                      "to":   {"recordId":"R-2","location":"San Francisco","year":1851}
                    }
                    """))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.plausible").value(false))
            .andExpect(jsonPath("$.rulesTriggered[0]").value("physical_impossibility"))
            .andExpect(jsonPath("$.confidenceAdjustment").value(50));
    }
}
