package com.spexture.linkage_engine;

/**
 * Flags a low-confidence warning when the margin between available and required travel days
 * is less than {@value #NARROW_MARGIN_DAYS} days — the movement is technically possible but tight.
 */
public class NarrowMarginRule implements ConflictRule {

    static final int NARROW_MARGIN_DAYS = 5;

    @Override
    public RuleResult check(SpatioTemporalRequest request,
                            HistoricalTransitService.TransitEstimate estimate,
                            double availableDays) {
        double margin = availableDays - estimate.travelDays();
        // Only flag when the trip is possible but tight (margin < threshold and margin >= 0)
        boolean narrow = margin >= 0 && margin < NARROW_MARGIN_DAYS;
        return new RuleResult(
            "narrow_margin",
            narrow,
            false,   // plausible, but flagged
            narrow ? 15 : 0,
            narrow
                ? String.format("Margin of %.1f days is tight (threshold: %d days).", margin, NARROW_MARGIN_DAYS)
                : String.format("Margin of %.1f days is comfortable.", margin)
        );
    }
}
