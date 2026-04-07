package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;

import org.junit.jupiter.api.Test;

import com.fasterxml.jackson.databind.ObjectMapper;

class SpatioTemporalSerializationTest {

    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    void requestSerializesAndDeserializes() throws Exception {
        SpatioTemporalRequest req = new SpatioTemporalRequest(
            new SpatioTemporalRecord("R-1", null, "Boston", 42.36, -71.06, 1850, 3, null),
            new SpatioTemporalRecord("R-2", null, "Philadelphia", null, null, 1851, null, null)
        );

        String json = mapper.writeValueAsString(req);
        assertThat(json).contains("Boston").contains("Philadelphia").contains("1850");

        SpatioTemporalRequest deserialized = mapper.readValue(json, SpatioTemporalRequest.class);
        assertThat(deserialized.from().location()).isEqualTo("Boston");
        assertThat(deserialized.from().lat()).isEqualTo(42.36);
        assertThat(deserialized.to().location()).isEqualTo("Philadelphia");
        assertThat(deserialized.to().lat()).isNull();
        assertThat(deserialized.from().month()).isEqualTo(3);
        assertThat(deserialized.to().month()).isNull();
    }

    @Test
    void responseSerializesAndDeserializes() throws Exception {
        SpatioTemporalResponse resp = new SpatioTemporalResponse(
            false, 120.5, 365.0, -244.5, "ocean_ship",
            List.of("physical_impossibility"), 50
        );

        String json = mapper.writeValueAsString(resp);
        assertThat(json).contains("ocean_ship").contains("physical_impossibility");

        SpatioTemporalResponse deserialized = mapper.readValue(json, SpatioTemporalResponse.class);
        assertThat(deserialized.plausible()).isFalse();
        assertThat(deserialized.travelDays()).isEqualTo(120.5);
        assertThat(deserialized.transitMode()).isEqualTo("ocean_ship");
        assertThat(deserialized.rulesTriggered()).containsExactly("physical_impossibility");
        assertThat(deserialized.confidenceAdjustment()).isEqualTo(50);
    }
}
