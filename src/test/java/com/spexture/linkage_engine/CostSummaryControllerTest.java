package com.spexture.linkage_engine;

import static org.hamcrest.Matchers.containsString;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

@ExtendWith(MockitoExtension.class)
class CostSummaryControllerTest {

    private MockMvc mockMvc;

    @Mock
    private MonthlyTaggedCostService monthlyTaggedCostService;

    @BeforeEach
    void setUp() {
        mockMvc = MockMvcBuilders.standaloneSetup(new CostSummaryController(monthlyTaggedCostService)).build();
    }

    @Test
    void monthToDatePage_ok_containsAmountAndHtml() throws Exception {
        when(monthlyTaggedCostService.monthToDate())
                .thenReturn(
                        new MonthToDateCostView(
                                "OK",
                                "App=linkage-engine",
                                "12.34",
                                "2026-05-01",
                                "2026-06-01",
                                "UnblendedCost in USD (UTC month)."));

        mockMvc.perform(get("/v1/cost/month-to-date/page"))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith(MediaType.TEXT_HTML))
                .andExpect(content().string(containsString("12.34")))
                .andExpect(content().string(containsString("Month-to-date AWS cost")))
                .andExpect(content().string(containsString("App=linkage-engine")));
    }

    @Test
    void monthToDatePage_disabled_showsStatus() throws Exception {
        when(monthlyTaggedCostService.monthToDate())
                .thenReturn(
                        new MonthToDateCostView(
                                "DISABLED",
                                "App=linkage-engine",
                                null,
                                "2026-05-01",
                                "2026-06-01",
                                "Set LINKAGE_COST_ENABLED=true on the ECS task to query Cost Explorer."));

        mockMvc.perform(get("/v1/cost/month-to-date/page"))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith(MediaType.TEXT_HTML))
                .andExpect(content().string(containsString("DISABLED")))
                .andExpect(content().string(containsString("[2026-05-01, 2026-06-01)")))
                .andExpect(content().string(containsString("LINKAGE_COST_ENABLED")));
    }
}
