package com.spexture.linkage_engine;

import org.springframework.stereotype.Component;

/**
 * Penalises candidate pairs where the implied ages across the two records
 * are inconsistent — i.e. age regresses, or an implied age falls outside
 * the human lifespan.
 *
 * <p>Uses {@link AgeEstimator} to compute the verdict. Penalties:
 * <ul>
 *   <li>CONTRADICTS (age regressed) — 40 pts, sets plausible=false</li>
 *   <li>IMPLAUSIBLE (age outside [0,120]) — 50 pts, sets plausible=false</li>
 *   <li>CONSISTENT or UNKNOWN — no penalty</li>
 * </ul>
 *
 * <p>Skipped silently when neither record carries a birth year.
 */
@Component
public class AgeConsistencyRule implements ConflictRule {

    static final String RULE_NAME = "AgeConsistencyRule";

    private final AgeEstimator ageEstimator;

    public AgeConsistencyRule(AgeEstimator ageEstimator) {
        this.ageEstimator = ageEstimator;
    }

    @Override
    public RuleResult check(SpatioTemporalRequest request,
                            HistoricalTransitService.TransitEstimate estimate,
                            double availableDays) {

        AgeEstimator.AgeConsistencyResult result =
            ageEstimator.checkConsistency(request.from(), request.to());

        return switch (result.verdict()) {
            case CONSISTENT -> new RuleResult(RULE_NAME, false, false, 0, result.reason());
            case UNKNOWN    -> new RuleResult(RULE_NAME, false, false, 0, result.reason());
            case CONTRADICTS -> new RuleResult(RULE_NAME, true, true, 40, result.reason());
            case IMPLAUSIBLE -> new RuleResult(RULE_NAME, true, true, 50, result.reason());
        };
    }
}
