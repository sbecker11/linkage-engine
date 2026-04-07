package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;

import org.junit.jupiter.api.Test;

class HistoricalTransitServiceTest {

    private final HistoricalTransitService service = new HistoricalTransitService();

    private static SpatioTemporalRecord rec(String location, int year) {
        return new SpatioTemporalRecord("id", location, null, null, year, null);
    }

    @Test
    void bostonToPhiladelphia1840UsesRailroad() {
        // ~300 miles, 1840 = eastern railroad era (200 mi/day) → ~1.5 days
        HistoricalTransitService.TransitEstimate est =
            service.estimate(rec("Boston", 1840), rec("Philadelphia", 1840));

        assertThat(est.mode()).isEqualTo("railroad_eastern");
        assertThat(est.travelDays()).isLessThan(3.0);
        assertThat(est.distanceMiles()).isBetween(200.0, 400.0);
    }

    @Test
    void bostonToSanFrancisco1848UsesOceanShip() {
        // Pre-transcontinental (1848 < 1869): ship around Cape Horn
        HistoricalTransitService.TransitEstimate est =
            service.estimate(rec("Boston", 1848), rec("San Francisco", 1848));

        assertThat(est.mode()).isEqualTo("ocean_ship");
        // Cape Horn route ≥ 18,000 miles at 150 mi/day → ≥ 120 days
        assertThat(est.travelDays()).isGreaterThan(100.0);
    }

    @Test
    void bostonToSanFrancisco1870UsesTranscontinentalRail() {
        HistoricalTransitService.TransitEstimate est =
            service.estimate(rec("Boston", 1870), rec("San Francisco", 1870));

        assertThat(est.mode()).isEqualTo("railroad_transcontinental");
        // ~3000 miles at 400 mi/day → ~7.5 days
        assertThat(est.travelDays()).isBetween(5.0, 15.0);
    }

    @Test
    void pre1830UsesHorseCoach() {
        HistoricalTransitService.TransitEstimate est =
            service.estimate(rec("Boston", 1820), rec("Philadelphia", 1820));

        assertThat(est.mode()).isEqualTo("horse_coach");
        assertThat(est.speedMilesPerDay()).isEqualTo(50.0);
    }

    @Test
    void haversineKnownDistance() {
        // Boston to New York: ~190 miles
        double dist = HistoricalTransitService.haversine(42.36, -71.06, 40.71, -74.01);
        assertThat(dist).isCloseTo(190.0, within(20.0));
    }

    @Test
    void coordResolutionFallsBackToCentralUS() {
        SpatioTemporalRecord unknown = new SpatioTemporalRecord("id", "UnknownTown", null, null, 1850, null);
        double[] coords = service.resolveCoords(unknown);
        // Central US default
        assertThat(coords[0]).isCloseTo(39.5, within(1.0));
    }

    @Test
    void explicitLatLonOverridesCity() {
        SpatioTemporalRecord rec = new SpatioTemporalRecord("id", "Boston", 51.5, -0.1, 1850, null);
        double[] coords = service.resolveCoords(rec);
        assertThat(coords[0]).isEqualTo(51.5);
        assertThat(coords[1]).isEqualTo(-0.1);
    }
}
