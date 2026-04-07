package com.spexture.linkage_engine;

/**
 * Flags the record pair as implausible when the implied age at either record
 * would be outside the human lifespan (0–120 years).
 *
 * <p>Requires {@code from.recordId()} to carry an optional birth-year hint encoded as
 * {@code "BORN:YYYY"} prefix in the recordId — or falls back to a no-op when no birth year
 * is available (conservative: does not penalise when data is absent).
 */
public class BiologicalPlausibilityRule implements ConflictRule {

    private static final int MIN_AGE = 0;
    private static final int MAX_AGE = 120;

    @Override
    public RuleResult check(SpatioTemporalRequest request,
                            HistoricalTransitService.TransitEstimate estimate,
                            double availableDays) {
        Integer birthYear = extractBirthYear(request.from().recordId());
        if (birthYear == null) {
            birthYear = extractBirthYear(request.to().recordId());
        }
        if (birthYear == null) {
            return new RuleResult("biological_plausibility", false, false, 0,
                "No birth year available; biological check skipped.");
        }

        int ageAtFrom = request.from().year() - birthYear;
        int ageAtTo   = request.to().year()   - birthYear;

        boolean implausible = ageAtFrom < MIN_AGE || ageAtFrom > MAX_AGE
                           || ageAtTo   < MIN_AGE || ageAtTo   > MAX_AGE;

        return new RuleResult(
            "biological_plausibility",
            implausible,
            implausible,
            implausible ? 50 : 0,
            implausible
                ? String.format("Implied ages (%d, %d) are outside plausible range [%d, %d].",
                    ageAtFrom, ageAtTo, MIN_AGE, MAX_AGE)
                : String.format("Ages at records (%d, %d) are biologically plausible.", ageAtFrom, ageAtTo)
        );
    }

    /**
     * Extracts birth year from a recordId prefixed with {@code "BORN:YYYY:"}, e.g. {@code "BORN:1820:R-001"}.
     * Returns null if no such prefix is present.
     */
    static Integer extractBirthYear(String recordId) {
        if (recordId == null || !recordId.startsWith("BORN:")) return null;
        try {
            String[] parts = recordId.split(":", 3);
            return Integer.parseInt(parts[1]);
        } catch (NumberFormatException | ArrayIndexOutOfBoundsException e) {
            return null;
        }
    }
}
