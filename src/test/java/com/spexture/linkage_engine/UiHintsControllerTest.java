package com.spexture.linkage_engine;

import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.core.env.Environment;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

@ExtendWith(MockitoExtension.class)
class UiHintsControllerTest {

    private MockMvc mockMvc;

    @Mock
    private Environment environment;

    @BeforeEach
    void setUp() {
        mockMvc = MockMvcBuilders.standaloneSetup(new UiHintsController(environment)).build();
    }

    @Test
    void features_localProfile_hidesCostPageLink() throws Exception {
        when(environment.getActiveProfiles()).thenReturn(new String[] {"local"});
        mockMvc.perform(get("/v1/ui/features"))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$.showCostMonthToDatePageLink").value(false));
    }

    @Test
    void features_prodProfile_showsCostPageLink() throws Exception {
        when(environment.getActiveProfiles()).thenReturn(new String[] {"prod"});
        mockMvc.perform(get("/v1/ui/features"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.showCostMonthToDatePageLink").value(true));
    }

    @Test
    void features_emptyProfiles_showsCostPageLink() throws Exception {
        when(environment.getActiveProfiles()).thenReturn(new String[] {});
        mockMvc.perform(get("/v1/ui/features"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.showCostMonthToDatePageLink").value(true));
    }
}
