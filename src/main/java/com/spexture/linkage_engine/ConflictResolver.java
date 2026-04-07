package com.spexture.linkage_engine;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * Runs the ordered {@link ConflictRule} chain and aggregates results into a
 * {@link SpatioTemporalResponse}.
 */
@Service
public class ConflictResolver {

    private static final Logger log = LoggerFactory.getLogger(ConflictResolver.class);

    private final HistoricalTransitService transitService;
    private final List<ConflictRule> rules;

    public ConflictResolver(HistoricalTransitService transitService, List<ConflictRule> rules) {
        this.transitService = transitService;
        this.rules = rules;
    }

    public SpatioTemporalResponse resolve(SpatioTemporalRequest request) {
        HistoricalTransitService.TransitEstimate estimate =
            transitService.estimate(request.from(), request.to());

        double availableDays = computeAvailableDays(request.from(), request.to());
        double margin = availableDays - estimate.travelDays();

        List<String> rulesTriggered = new ArrayList<>();
        Map<String, Integer> rulePenalties = new LinkedHashMap<>();
        boolean plausible = true;
        int totalPenalty = 0;

        for (ConflictRule rule : rules) {
            ConflictRule.RuleResult result = rule.check(request, estimate, availableDays);
            if (result.triggered()) {
                rulesTriggered.add(result.ruleName());
                rulePenalties.put(result.ruleName(), result.confidencePenalty());
                totalPenalty += result.confidencePenalty();
                log.debug("[ConflictResolver] rule={} triggered={} implausible={} reason={}",
                    result.ruleName(), result.triggered(), result.implausible(), result.reason());
            }
            if (result.implausible()) {
                plausible = false;
            }
        }

        log.info("[ConflictResolver] from={} to={} year={} dist={}mi mode={} travelDays={} availDays={} plausible={}",
            request.from().location(), request.to().location(),
            request.from().year(), String.format("%.1f", estimate.distanceMiles()), estimate.mode(),
            String.format("%.1f", estimate.travelDays()), String.format("%.1f", availableDays), plausible);

        return new SpatioTemporalResponse(
            plausible,
            estimate.travelDays(),
            availableDays,
            margin,
            estimate.mode(),
            rulesTriggered,
            Math.min(50, totalPenalty),
            rulePenalties
        );
    }

    /**
     * Available days = (year delta × 365) + (month delta × 30).
     * Minimum 1 to avoid division-by-zero edge cases.
     */
    static double computeAvailableDays(SpatioTemporalRecord from, SpatioTemporalRecord to) {
        int yearDelta = Math.abs(to.year() - from.year());
        int monthDelta = 0;
        if (from.month() != null && to.month() != null) {
            monthDelta = to.month() - from.month();
            if (to.year() < from.year()) monthDelta = -monthDelta;
        }
        double days = yearDelta * 365.0 + monthDelta * 30.0;
        // When same year and no month precision, assume a half-year gap as a conservative default.
        if (yearDelta == 0 && from.month() == null && to.month() == null) {
            return 182.5;
        }
        return Math.max(1.0, days);
    }
}
