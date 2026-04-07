package com.spexture.linkage_engine;

import java.util.Map;

import org.springframework.stereotype.Service;

/**
 * Estimates minimum travel time between two locations given a historical year.
 *
 * <p>Speed table (miles/day):
 * <ul>
 *   <li>pre-1830: horse/coach ~50</li>
 *   <li>1830–1868: eastern railroad ~200</li>
 *   <li>1869+: transcontinental rail ~400</li>
 *   <li>any: ocean/coastal ship ~150 (used when land route crosses an ocean)</li>
 *   <li>any: on foot ~20</li>
 * </ul>
 *
 * <p>Distances are straight-line (haversine) — actual routes are longer, so this is
 * generous to plausibility (under-estimates required travel time).
 */
@Service
public class HistoricalTransitService {

    /** Known city coordinates (name → {lat, lon}). */
    private static final Map<String, double[]> CITY_COORDS = Map.ofEntries(
        Map.entry("boston",        new double[]{42.36, -71.06}),
        Map.entry("new york",      new double[]{40.71, -74.01}),
        Map.entry("new york city", new double[]{40.71, -74.01}),
        Map.entry("nyc",           new double[]{40.71, -74.01}),
        Map.entry("philadelphia",  new double[]{39.95, -75.17}),
        Map.entry("baltimore",     new double[]{39.29, -76.61}),
        Map.entry("washington dc", new double[]{38.91, -77.04}),
        Map.entry("richmond",      new double[]{37.54, -77.43}),
        Map.entry("charleston",    new double[]{32.78, -79.94}),
        Map.entry("new orleans",   new double[]{29.95, -90.07}),
        Map.entry("chicago",       new double[]{41.88, -87.63}),
        Map.entry("st. louis",     new double[]{38.63, -90.20}),
        Map.entry("cincinnati",    new double[]{39.10, -84.51}),
        Map.entry("pittsburgh",    new double[]{40.44, -79.99}),
        Map.entry("detroit",       new double[]{42.33, -83.05}),
        Map.entry("cleveland",     new double[]{41.50, -81.69}),
        Map.entry("indianapolis",  new double[]{39.77, -86.16}),
        Map.entry("atlanta",       new double[]{33.75, -84.39}),
        Map.entry("houston",       new double[]{29.76, -95.37}),
        Map.entry("san francisco", new double[]{37.77, -122.42}),
        Map.entry("los angeles",   new double[]{34.05, -118.24}),
        Map.entry("portland",      new double[]{45.52, -122.68}),
        Map.entry("seattle",       new double[]{47.61, -122.33}),
        Map.entry("denver",        new double[]{39.74, -104.98}),
        Map.entry("salt lake city",new double[]{40.76, -111.89}),
        Map.entry("omaha",         new double[]{41.26, -95.94}),
        Map.entry("kansas city",   new double[]{39.10, -94.58}),
        Map.entry("memphis",       new double[]{35.15, -90.05}),
        Map.entry("nashville",     new double[]{36.17, -86.78}),
        Map.entry("louisville",    new double[]{38.25, -85.76}),
        Map.entry("buffalo",       new double[]{42.89, -78.88}),
        Map.entry("albany",        new double[]{42.65, -73.75}),
        Map.entry("providence",    new double[]{41.82, -71.42}),
        Map.entry("hartford",      new double[]{41.76, -72.68}),
        Map.entry("portland me",   new double[]{43.66, -70.26})
    );

    /** Threshold longitude west of which a city is considered "far west" (pre-1869 rail gap). */
    private static final double FAR_WEST_LONGITUDE = -100.0;

    public TransitEstimate estimate(SpatioTemporalRecord from, SpatioTemporalRecord to) {
        double[] fromCoords = resolveCoords(from);
        double[] toCoords   = resolveCoords(to);
        double distanceMiles = haversine(fromCoords[0], fromCoords[1], toCoords[0], toCoords[1]);

        int year = from.year();
        String mode;
        double speedMilesPerDay;

        boolean crossesContinent = crossesContinent(fromCoords, toCoords);

        if (crossesContinent && year < 1869) {
            // Pre-transcontinental: ship around Cape Horn or overland wagon
            mode = "ocean_ship";
            speedMilesPerDay = 150.0;
            // Cape Horn route is ~18,000 miles; use actual sea distance as a floor
            distanceMiles = Math.max(distanceMiles, 18_000.0);
        } else if (year < 1830) {
            mode = "horse_coach";
            speedMilesPerDay = 50.0;
        } else if (year < 1869) {
            mode = "railroad_eastern";
            speedMilesPerDay = 200.0;
        } else {
            mode = "railroad_transcontinental";
            speedMilesPerDay = 400.0;
        }

        double travelDays = distanceMiles / speedMilesPerDay;
        return new TransitEstimate(travelDays, distanceMiles, mode, speedMilesPerDay);
    }

    /** Resolves lat/lon from the record, falling back to the city table. */
    double[] resolveCoords(SpatioTemporalRecord record) {
        if (record.lat() != null && record.lon() != null) {
            return new double[]{record.lat(), record.lon()};
        }
        if (record.location() != null) {
            double[] coords = CITY_COORDS.get(record.location().toLowerCase().trim());
            if (coords != null) return coords;
        }
        // Unknown location — return a central US default (generous: minimises estimated distance)
        return new double[]{39.5, -98.35};
    }

    /** True when the two locations span the continental divide (one east, one far west). */
    private boolean crossesContinent(double[] from, double[] to) {
        return (from[1] > FAR_WEST_LONGITUDE && to[1] <= FAR_WEST_LONGITUDE)
            || (to[1] > FAR_WEST_LONGITUDE && from[1] <= FAR_WEST_LONGITUDE);
    }

    /** Haversine great-circle distance in miles. */
    static double haversine(double lat1, double lon1, double lat2, double lon2) {
        final double R = 3_958.8; // Earth radius in miles
        double dLat = Math.toRadians(lat2 - lat1);
        double dLon = Math.toRadians(lon2 - lon1);
        double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
            + Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2))
            * Math.sin(dLon / 2) * Math.sin(dLon / 2);
        return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    }

    record TransitEstimate(
        double travelDays,
        double distanceMiles,
        String mode,
        double speedMilesPerDay
    ) {}
}
