package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class ConflictRulesTest {

    private static final HistoricalTransitService.TransitEstimate ESTIMATE_10_DAYS =
        new HistoricalTransitService.TransitEstimate(10.0, 2000.0, "railroad_eastern", 200.0);

    private static final HistoricalTransitService.TransitEstimate ESTIMATE_2_DAYS =
        new HistoricalTransitService.TransitEstimate(2.0, 400.0, "railroad_eastern", 200.0);

    private static SpatioTemporalRequest req(String fromId, String toId, int fromYear, int toYear) {
        return new SpatioTemporalRequest(
            new SpatioTemporalRecord(fromId, null, "Boston", null, null, fromYear, null, null),
            new SpatioTemporalRecord(toId,   null, "Philadelphia", null, null, toYear, null, null)
        );
    }

    // ── PhysicalImpossibilityRule ──────────────────────────────────────────────

    @Test
    void physicalImpossibility_triggersWhenTravelExceedsAvailable() {
        PhysicalImpossibilityRule rule = new PhysicalImpossibilityRule();
        // 10 days required, only 5 available
        ConflictRule.RuleResult result = rule.check(req("A", "B", 1850, 1850), ESTIMATE_10_DAYS, 5.0);
        assertThat(result.triggered()).isTrue();
        assertThat(result.implausible()).isTrue();
        assertThat(result.confidencePenalty()).isEqualTo(50);
    }

    @Test
    void physicalImpossibility_doesNotTriggerWhenTravelFits() {
        PhysicalImpossibilityRule rule = new PhysicalImpossibilityRule();
        // 2 days required, 365 available
        ConflictRule.RuleResult result = rule.check(req("A", "B", 1850, 1851), ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isFalse();
        assertThat(result.implausible()).isFalse();
        assertThat(result.confidencePenalty()).isEqualTo(0);
    }

    @Test
    void physicalImpossibility_exactBoundary() {
        PhysicalImpossibilityRule rule = new PhysicalImpossibilityRule();
        // Exactly equal: 10 days required, 10 available → possible (not strictly greater)
        ConflictRule.RuleResult result = rule.check(req("A", "B", 1850, 1850), ESTIMATE_10_DAYS, 10.0);
        assertThat(result.triggered()).isFalse();
    }

    // ── BiologicalPlausibilityRule ─────────────────────────────────────────────

    @Test
    void biological_triggersWhenAgeNegative() {
        BiologicalPlausibilityRule rule = new BiologicalPlausibilityRule();
        // Born 1860, record from 1850 → age = -10
        SpatioTemporalRequest r = req("BORN:1860:R-1", "R-2", 1850, 1855);
        ConflictRule.RuleResult result = rule.check(r, ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isTrue();
        assertThat(result.implausible()).isTrue();
    }

    @Test
    void biological_triggersWhenAgeOver120() {
        BiologicalPlausibilityRule rule = new BiologicalPlausibilityRule();
        // Born 1700, record from 1850 → age = 150
        SpatioTemporalRequest r = req("BORN:1700:R-1", "R-2", 1850, 1855);
        ConflictRule.RuleResult result = rule.check(r, ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isTrue();
    }

    @Test
    void biological_doesNotTriggerForNormalAge() {
        BiologicalPlausibilityRule rule = new BiologicalPlausibilityRule();
        // Born 1820, record from 1850 → age = 30
        SpatioTemporalRequest r = req("BORN:1820:R-1", "R-2", 1850, 1855);
        ConflictRule.RuleResult result = rule.check(r, ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isFalse();
    }

    @Test
    void biological_skipsWhenNoBirthYear() {
        BiologicalPlausibilityRule rule = new BiologicalPlausibilityRule();
        SpatioTemporalRequest r = req("R-1", "R-2", 1850, 1855);
        ConflictRule.RuleResult result = rule.check(r, ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isFalse();
        assertThat(result.reason()).contains("skipped");
    }

    @Test
    void biological_extractBirthYear() {
        assertThat(BiologicalPlausibilityRule.extractBirthYear("BORN:1820:R-001")).isEqualTo(1820);
        assertThat(BiologicalPlausibilityRule.extractBirthYear("R-001")).isNull();
        assertThat(BiologicalPlausibilityRule.extractBirthYear(null)).isNull();
        assertThat(BiologicalPlausibilityRule.extractBirthYear("BORN:bad:R-001")).isNull();
    }

    // ── NarrowMarginRule ───────────────────────────────────────────────────────

    @Test
    void narrowMargin_triggersWhenMarginBelowThreshold() {
        NarrowMarginRule rule = new NarrowMarginRule();
        // 2 days required, 4 available → margin = 2 < 5
        ConflictRule.RuleResult result = rule.check(req("A", "B", 1850, 1850), ESTIMATE_2_DAYS, 4.0);
        assertThat(result.triggered()).isTrue();
        assertThat(result.implausible()).isFalse();  // plausible but flagged
        assertThat(result.confidencePenalty()).isEqualTo(15);
    }

    @Test
    void narrowMargin_doesNotTriggerWhenComfortableMargin() {
        NarrowMarginRule rule = new NarrowMarginRule();
        // 2 days required, 100 available → margin = 98
        ConflictRule.RuleResult result = rule.check(req("A", "B", 1850, 1851), ESTIMATE_2_DAYS, 100.0);
        assertThat(result.triggered()).isFalse();
        assertThat(result.confidencePenalty()).isEqualTo(0);
    }

    @Test
    void narrowMargin_doesNotTriggerWhenAlreadyImpossible() {
        NarrowMarginRule rule = new NarrowMarginRule();
        // 10 days required, 5 available → margin = -5 (negative, not "narrow")
        ConflictRule.RuleResult result = rule.check(req("A", "B", 1850, 1850), ESTIMATE_10_DAYS, 5.0);
        assertThat(result.triggered()).isFalse();
    }

    // ── AgeEstimator ──────────────────────────────────────────────────────────

    private final AgeEstimator ageEstimator = new AgeEstimator();
    private final AgeConsistencyRule ageRule = new AgeConsistencyRule(ageEstimator);

    private static SpatioTemporalRequest reqWithBirthYears(
            int fromYear, Integer fromBirth, int toYear, Integer toBirth) {
        return new SpatioTemporalRequest(
            new SpatioTemporalRecord("R-A", null, "Boston",       null, null, fromYear, null, fromBirth),
            new SpatioTemporalRecord("R-B", null, "Philadelphia", null, null, toYear,   null, toBirth)
        );
    }

    @Test
    void ageConsistency_consistentWhenAgesAdvanceNormally() {
        // Born 1820: age 30 in 1850, age 31 in 1851 — consistent
        ConflictRule.RuleResult result = ageRule.check(
            reqWithBirthYears(1850, 1820, 1851, 1820), ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isFalse();
        assertThat(result.confidencePenalty()).isEqualTo(0);
        assertThat(result.reason()).contains("consistent");
    }

    @Test
    void ageConsistency_contradictsWhenAgeDeltaExceedsYearDelta() {
        // Record A: born 1820, event 1850 → age 30
        // Record B: born 1780, event 1851 → age 71
        // ageDelta = |71-30| = 41, yearDelta = 1, 41 > 1+5 → contradicts
        ConflictRule.RuleResult result = ageRule.check(
            reqWithBirthYears(1850, 1820, 1851, 1780), ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isTrue();
        assertThat(result.implausible()).isTrue();
        assertThat(result.confidencePenalty()).isEqualTo(40);
        assertThat(result.reason()).contains("exceeds year delta");
    }

    @Test
    void ageConsistency_implausibleWhenAgeOutsideLifespan() {
        // Born 1700, record in 1850 → age 150 — outside [0, 120]
        ConflictRule.RuleResult result = ageRule.check(
            reqWithBirthYears(1850, 1700, 1851, 1700), ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isTrue();
        assertThat(result.implausible()).isTrue();
        assertThat(result.confidencePenalty()).isEqualTo(50);
        assertThat(result.reason()).contains("outside viable range");
    }

    @Test
    void ageConsistency_skippedWhenNoBirthYear() {
        // No birth year on either record — conservative skip
        ConflictRule.RuleResult result = ageRule.check(
            reqWithBirthYears(1850, null, 1851, null), ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isFalse();
        assertThat(result.confidencePenalty()).isEqualTo(0);
        assertThat(result.reason()).contains("skipped");
    }

    // ── GenderPlausibilityRule ─────────────────────────────────────────────────

    private static SpatioTemporalRequest reqWithNames(String givenA, String givenB) {
        return new SpatioTemporalRequest(
            new SpatioTemporalRecord("R-A", givenA, "Boston",       null, null, 1850, null, null),
            new SpatioTemporalRecord("R-B", givenB, "Philadelphia", null, null, 1851, null, null)
        );
    }

    private final GivenNameGenderProvider genderProvider = new GivenNameGenderProvider();
    private final GenderPlausibilityRule genderRule = new GenderPlausibilityRule(genderProvider);

    @Test
    void gender_penalisesWhenMaleVsFemale() {
        // John (M) vs Mary (F) → conflict → −20 pts, still plausible
        ConflictRule.RuleResult result = genderRule.check(
            reqWithNames("John", "Mary"), ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isTrue();
        assertThat(result.implausible()).isFalse();
        assertThat(result.confidencePenalty()).isEqualTo(20);
        assertThat(result.reason()).contains("conflict");
    }

    @Test
    void gender_noPenaltyWhenBothMale() {
        // John (M) vs Jon (M) → consistent → no penalty
        ConflictRule.RuleResult result = genderRule.check(
            reqWithNames("John", "Jon"), ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isFalse();
        assertThat(result.confidencePenalty()).isEqualTo(0);
    }

    @Test
    void gender_skippedWhenAmbiguous() {
        // Leslie (AMBIGUOUS) vs Leslie (AMBIGUOUS) → skipped
        ConflictRule.RuleResult result = genderRule.check(
            reqWithNames("Leslie", "Leslie"), ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isFalse();
        assertThat(result.confidencePenalty()).isEqualTo(0);
        assertThat(result.reason()).contains("skipped");
    }

    @Test
    void gender_skippedWhenUnknown() {
        // "Zxqvr" not in dataset → UNKNOWN → skipped
        ConflictRule.RuleResult result = genderRule.check(
            reqWithNames("Zxqvr", "Mary"), ESTIMATE_2_DAYS, 365.0);
        assertThat(result.triggered()).isFalse();
        assertThat(result.confidencePenalty()).isEqualTo(0);
        assertThat(result.reason()).contains("skipped");
    }

    // ── ConflictResolver.computeAvailableDays ─────────────────────────────────

    @Test
    void availableDays_yearDeltaOnly() {
        SpatioTemporalRecord from = new SpatioTemporalRecord("id", null, "Boston", null, null, 1850, null, null);
        SpatioTemporalRecord to   = new SpatioTemporalRecord("id", null, "Philadelphia", null, null, 1851, null, null);
        assertThat(ConflictResolver.computeAvailableDays(from, to)).isEqualTo(365.0);
    }

    @Test
    void availableDays_withMonths() {
        SpatioTemporalRecord from = new SpatioTemporalRecord("id", null, "Boston", null, null, 1850, 1, null);
        SpatioTemporalRecord to   = new SpatioTemporalRecord("id", null, "Philadelphia", null, null, 1850, 7, null);
        // 0 years + 6 months × 30 = 180 days
        assertThat(ConflictResolver.computeAvailableDays(from, to)).isEqualTo(180.0);
    }

    @Test
    void availableDays_sameYearNoMonth_returns365() {
        // Same year, no month precision → up to 365 days could separate the records
        SpatioTemporalRecord from = new SpatioTemporalRecord("id", null, "Boston", null, null, 1850, null, null);
        SpatioTemporalRecord to   = new SpatioTemporalRecord("id", null, "Philadelphia", null, null, 1850, null, null);
        assertThat(ConflictResolver.computeAvailableDays(from, to)).isEqualTo(365.0);
    }

    @Test
    void availableDays_minimumOne_whenMonthDataPresent() {
        // Same year, same month → minimum 1 day floor applies
        SpatioTemporalRecord from = new SpatioTemporalRecord("id", null, "Boston", null, null, 1850, 3, null);
        SpatioTemporalRecord to   = new SpatioTemporalRecord("id", null, "Philadelphia", null, null, 1850, 3, null);
        assertThat(ConflictResolver.computeAvailableDays(from, to)).isEqualTo(1.0);
    }
}
