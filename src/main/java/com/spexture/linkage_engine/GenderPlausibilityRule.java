package com.spexture.linkage_engine;

import org.springframework.stereotype.Component;

/**
 * Penalises candidate pairs where the two given names infer conflicting genders.
 *
 * Does NOT set plausible=false — gender inference is probabilistic and historical
 * records contain transcription errors and gender-neutral names. Applies a −20 pt
 * confidenceAdjustment when both names resolve to non-AMBIGUOUS, non-UNKNOWN
 * genders that differ.
 *
 * Fits the existing ConflictRule chain — registered automatically via
 * List<ConflictRule> injection in ConflictResolver. Zero orchestrator changes needed.
 */
@Component
public class GenderPlausibilityRule implements ConflictRule {

    static final int PENALTY = 20;
    static final String RULE_NAME = "GenderPlausibilityRule";

    private final GivenNameGenderProvider genderProvider;

    public GenderPlausibilityRule(GivenNameGenderProvider genderProvider) {
        this.genderProvider = genderProvider;
    }

    @Override
    public RuleResult check(SpatioTemporalRequest request,
                            HistoricalTransitService.TransitEstimate estimate,
                            double availableDays) {

        String nameA = request.from().givenName();
        String nameB = request.to().givenName();

        GivenNameGenderProvider.Gender gA = genderProvider.infer(nameA);
        GivenNameGenderProvider.Gender gB = genderProvider.infer(nameB);

        boolean inferrable = gA != GivenNameGenderProvider.Gender.UNKNOWN
                          && gA != GivenNameGenderProvider.Gender.AMBIGUOUS
                          && gB != GivenNameGenderProvider.Gender.UNKNOWN
                          && gB != GivenNameGenderProvider.Gender.AMBIGUOUS;

        if (!inferrable) {
            return new RuleResult(RULE_NAME, false, false, 0,
                "skipped — gender ambiguous or unknown for '" + nameA + "'/'" + nameB + "'");
        }

        if (gA != gB) {
            return new RuleResult(RULE_NAME, true, false, PENALTY,
                "gender conflict: '" + nameA + "' inferred " + gA
                + " vs '" + nameB + "' inferred " + gB);
        }

        return new RuleResult(RULE_NAME, false, false, 0,
            "gender consistent: both inferred " + gA);
    }
}
