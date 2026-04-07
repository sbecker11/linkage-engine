package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

class LocationStandardizerTest {

    private final LocationStandardizer standardizer = new LocationStandardizer();

    @ParameterizedTest(name = "''{0}'' → ''{1}''")
    @CsvSource({
        "Philly,          Philadelphia",
        "philly,          Philadelphia",
        "PHILLY,          Philadelphia",
        "NYC,             New York City",
        "nyc,             New York City",
        "SF,              San Francisco",
        "sf,              San Francisco",
        "LA,              Los Angeles",
        "BOS,             Boston",
        "CHI,             Chicago",
        "DC,              Washington DC",
        "ATL,             Atlanta",
        "HOU,             Houston",
        "PHL,             Philadelphia",
        "STL,             St. Louis",
        "NOLA,            New Orleans",
        "CINCY,           Cincinnati",
        "INDY,            Indianapolis"
    })
    void expandsAbbreviation(String input, String expected) {
        assertThat(standardizer.cleanse(input.trim())).isEqualTo(expected.trim());
    }

    @Test
    void doesNotAlterFullCityName() {
        assertThat(standardizer.cleanse("Philadelphia")).isEqualTo("Philadelphia");
        assertThat(standardizer.cleanse("Boston")).isEqualTo("Boston");
    }

    @Test
    void doesNotAlterUnrelatedText() {
        assertThat(standardizer.cleanse("John Smith, 1850")).isEqualTo("John Smith, 1850");
    }

    @Test
    void handlesNullAndBlank() {
        assertThat(standardizer.cleanse(null)).isNull();
        assertThat(standardizer.cleanse("   ")).isEqualTo("   ");
    }

    @Test
    void expandsAbbreviationInSentence() {
        assertThat(standardizer.cleanse("Born in Philly, died in NYC"))
            .isEqualTo("Born in Philadelphia, died in New York City");
    }
}
