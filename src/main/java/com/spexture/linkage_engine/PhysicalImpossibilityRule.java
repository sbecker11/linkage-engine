package com.spexture.linkage_engine;

/**
 * Flags the movement as implausible when required travel days exceed available days.
 */
@org.springframework.stereotype.Component
public class PhysicalImpossibilityRule implements ConflictRule {

    @Override
    public RuleResult check(SpatioTemporalRequest request,
                            HistoricalTransitService.TransitEstimate estimate,
                            double availableDays) {
        boolean impossible = estimate.travelDays() > availableDays;
        return new RuleResult(
            "physical_impossibility",
            impossible,
            impossible,
            impossible ? 50 : 0,
            impossible
                ? String.format("Travel requires %.1f days but only %.1f days available (mode: %s).",
                    estimate.travelDays(), availableDays, estimate.mode())
                : "Travel is physically possible."
        );
    }
}
