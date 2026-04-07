package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

class OCRNoiseReducerTest {

    private final OCRNoiseReducer reducer = new OCRNoiseReducer();

    @ParameterizedTest(name = "''{0}'' → ''{1}''")
    @CsvSource({
        "18S0, 1850",
        "185O, 1850",
        "l850, 1850",
        "I850, 1850",
        "18SO, 1850",
        "lSSO, 1550"
    })
    void fixesOcrYearTokens(String input, String expected) {
        assertThat(reducer.cleanse(input)).isEqualTo(expected);
    }

    @Test
    void fixesYearInSentence() {
        assertThat(reducer.cleanse("John Smith, Philly, 18S0"))
            .isEqualTo("John Smith, Philly, 1850");
    }

    @Test
    void doesNotAlterCleanYear() {
        assertThat(reducer.cleanse("1850")).isEqualTo("1850");
        assertThat(reducer.cleanse("born 1920 died 1985")).isEqualTo("born 1920 died 1985");
    }

    @Test
    void doesNotAlterShortTokens() {
        // "SF" is only 2 chars — should not be touched by the 4-char year pattern
        assertThat(reducer.cleanse("SF")).isEqualTo("SF");
    }

    @Test
    void handlesNullAndBlank() {
        assertThat(reducer.cleanse(null)).isNull();
        assertThat(reducer.cleanse("   ")).isEqualTo("   ");
    }
}
