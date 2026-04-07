package com.spexture.linkage_engine;

import org.springframework.stereotype.Component;

/**
 * Estimates age and checks age consistency across two genealogical records.
 *
 * <p>Given a birth year and an event year, computes the implied age. Given two
 * records for a candidate pair, checks whether the age delta is consistent with
 * the year delta — i.e. the person aged forward, not backward, and the implied
 * ages are within a human lifespan.
 *
 * <p>Used by {@link AgeConsistencyRule} and {@link BiologicalPlausibilityRule}.
 */
@Component
public class AgeEstimator {

    public static final int MIN_AGE = 0;
    public static final int MAX_AGE = 120;

    /**
     * Returns the implied age of a person at a given event year, or null if
     * birth year is unknown.
     */
    public Integer ageAt(Integer birthYear, int eventYear) {
        if (birthYear == null) return null;
        return eventYear - birthYear;
    }

    /**
     * Returns true if the implied age is within the human lifespan [0, 120].
     * Returns true (conservative) when birth year is unknown.
     */
    public boolean isAgeViable(Integer birthYear, int eventYear) {
        Integer age = ageAt(birthYear, eventYear);
        if (age == null) return true;
        return age >= MIN_AGE && age <= MAX_AGE;
    }

    /**
     * Checks whether the age delta between two records is consistent with the
     * year delta. For the same person, age must increase by approximately the
     * same number of years as the event years advance.
     *
     * <p>Returns an {@link AgeConsistencyResult} describing the outcome.
     * If either record lacks a birth year, returns UNKNOWN (conservative — no penalty).
     */
    public AgeConsistencyResult checkConsistency(SpatioTemporalRecord from, SpatioTemporalRecord to) {
        Integer birthYearFrom = from.birthYear();
        Integer birthYearTo   = to.birthYear();

        if (birthYearFrom == null && birthYearTo == null) {
            return new AgeConsistencyResult(Verdict.UNKNOWN, null, null, null,
                "No birth year available on either record; age consistency check skipped.");
        }

        // Derive each record's implied age using its own birth year when available,
        // falling back to the other record's birth year if only one is known.
        int ageAtFrom = from.year() - (birthYearFrom != null ? birthYearFrom : birthYearTo);
        int ageAtTo   = to.year()   - (birthYearTo   != null ? birthYearTo   : birthYearFrom);
        int yearDelta = to.year()   - from.year();

        // Either age is outside the human lifespan
        if (ageAtFrom < MIN_AGE || ageAtFrom > MAX_AGE || ageAtTo < MIN_AGE || ageAtTo > MAX_AGE) {
            return new AgeConsistencyResult(Verdict.IMPLAUSIBLE, ageAtFrom, ageAtTo, yearDelta,
                String.format("Implied ages (%d, %d) outside viable range [%d, %d].",
                    ageAtFrom, ageAtTo, MIN_AGE, MAX_AGE));
        }

        // |ageA - ageB| should equal |yearDelta| within a 5-year tolerance.
        // A larger discrepancy means the two records cannot belong to the same person.
        int ageDelta = Math.abs(ageAtTo - ageAtFrom);
        int expectedDelta = Math.abs(yearDelta);
        if (ageDelta > expectedDelta + 5) {
            return new AgeConsistencyResult(Verdict.CONTRADICTS, ageAtFrom, ageAtTo, yearDelta,
                String.format("Age delta %d exceeds year delta %d by more than 5 — records contradict same-person identity.",
                    ageDelta, expectedDelta));
        }

        return new AgeConsistencyResult(Verdict.CONSISTENT, ageAtFrom, ageAtTo, yearDelta,
            String.format("Ages consistent: %d at %d → %d at %d (year delta %+d, age delta %d).",
                ageAtFrom, from.year(), ageAtTo, to.year(), yearDelta, ageDelta));
    }

    public enum Verdict { CONSISTENT, CONTRADICTS, IMPLAUSIBLE, UNKNOWN }

    public record AgeConsistencyResult(
        Verdict verdict,
        Integer ageAtFrom,
        Integer ageAtTo,
        Integer yearDelta,
        String reason
    ) {}
}
