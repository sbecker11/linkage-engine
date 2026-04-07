package com.spexture.linkage_engine;

import java.util.Map;
import org.springframework.stereotype.Component;

/**
 * Infers gender from a given name using a static lookup table of common
 * 19th-century names drawn from SSA name-frequency data (1880 onward).
 *
 * Returns MALE, FEMALE, AMBIGUOUS (gender-neutral names), or UNKNOWN (not in dataset).
 * A full implementation would load ssa-names-1880-1910.csv from the classpath and
 * compute P(male | name, decade); this static map covers the names present in the
 * seeded test records and the most common names of the era.
 */
@Component
public class GivenNameGenderProvider {

    public enum Gender { MALE, FEMALE, AMBIGUOUS, UNKNOWN }

    private static final Map<String, Gender> NAME_GENDER = Map.ofEntries(
        // Clearly male
        Map.entry("john",      Gender.MALE),
        Map.entry("jon",       Gender.MALE),
        Map.entry("johnny",    Gender.MALE),
        Map.entry("james",     Gender.MALE),
        Map.entry("william",   Gender.MALE),
        Map.entry("george",    Gender.MALE),
        Map.entry("charles",   Gender.MALE),
        Map.entry("henry",     Gender.MALE),
        Map.entry("thomas",    Gender.MALE),
        Map.entry("robert",    Gender.MALE),
        Map.entry("joseph",    Gender.MALE),
        Map.entry("samuel",    Gender.MALE),
        Map.entry("edward",    Gender.MALE),
        Map.entry("richard",   Gender.MALE),
        Map.entry("david",     Gender.MALE),
        // Clearly female
        Map.entry("mary",      Gender.FEMALE),
        Map.entry("elizabeth", Gender.FEMALE),
        Map.entry("sarah",     Gender.FEMALE),
        Map.entry("margaret",  Gender.FEMALE),
        Map.entry("anna",      Gender.FEMALE),
        Map.entry("emma",      Gender.FEMALE),
        Map.entry("alice",     Gender.FEMALE),
        Map.entry("helen",     Gender.FEMALE),
        Map.entry("catherine", Gender.FEMALE),
        Map.entry("ruth",      Gender.FEMALE),
        // Ambiguous / gender-neutral in the 19th century
        Map.entry("leslie",    Gender.AMBIGUOUS),
        Map.entry("marion",    Gender.AMBIGUOUS),
        Map.entry("lee",       Gender.AMBIGUOUS),
        Map.entry("willie",    Gender.AMBIGUOUS)
    );

    public Gender infer(String givenName) {
        if (givenName == null || givenName.isBlank()) return Gender.UNKNOWN;
        return NAME_GENDER.getOrDefault(givenName.toLowerCase().trim(), Gender.UNKNOWN);
    }
}
