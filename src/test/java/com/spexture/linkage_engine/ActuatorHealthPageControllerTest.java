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
import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthEndpoint;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

@ExtendWith(MockitoExtension.class)
class ActuatorHealthPageControllerTest {

    private MockMvc mockMvc;

    @Mock
    private HealthEndpoint healthEndpoint;

    @BeforeEach
    void setUp() {
        mockMvc = MockMvcBuilders.standaloneSetup(new ActuatorHealthPageController(healthEndpoint)).build();
    }

    @Test
    void page_showsActuatorStatusAndDetails() throws Exception {
        when(healthEndpoint.health())
                .thenReturn(Health.up().withDetail("database", "PostgreSQL").build());

        mockMvc.perform(get("/v1/health/page"))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith(MediaType.TEXT_HTML))
                .andExpect(content().string(containsString("Actuator health")))
                .andExpect(content().string(containsString("UP")))
                .andExpect(content().string(containsString("PostgreSQL")))
                .andExpect(content().string(containsString("href=\"/actuator/health\"")))
                .andExpect(content().string(containsString("href=\"/chord-diagram.html\"")));
    }

    @Test
    void page_escapesDetailText() throws Exception {
        when(healthEndpoint.health())
                .thenReturn(Health.down().withDetail("error", "<script>alert(1)</script>").build());

        mockMvc.perform(get("/v1/health/page"))
                .andExpect(status().isOk())
                .andExpect(content().string(containsString("DOWN")))
                .andExpect(content().string(containsString("&lt;script&gt;")))
                .andExpect(content().string(org.hamcrest.Matchers.not(containsString("<script>alert"))));
    }
}
