package com.spexture.linkage_engine;

/**
 * Single-responsibility spatio-temporal conflict check.
 * Mirrors the {@link CleansingProvider} pattern.
 */
public interface ConflictRule {

    RuleResult check(SpatioTemporalRequest request, HistoricalTransitService.TransitEstimate estimate,
                     double availableDays);

    record RuleResult(
        String ruleName,
        boolean triggered,
        boolean implausible,
        int confidencePenalty,
        String reason
    ) {}
}
