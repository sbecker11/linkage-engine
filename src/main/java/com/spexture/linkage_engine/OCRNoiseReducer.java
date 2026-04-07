package com.spexture.linkage_engine;

import java.util.regex.Pattern;

/**
 * Fixes common OCR digit/letter substitution errors found in historical record scans.
 *
 * <p>Rules applied in order:
 * <ul>
 *   <li>4-digit year-like tokens: digit {@code S} → {@code 5} (e.g. {@code 18S0} → {@code 1850})</li>
 *   <li>4-digit year-like tokens: digit {@code O} → {@code 0} (e.g. {@code 185O} → {@code 1850})</li>
 *   <li>4-digit year-like tokens: digit {@code l} or {@code I} → {@code 1} (e.g. {@code l850} → {@code 1850})</li>
 *   <li>Standalone {@code l} surrounded by digits → {@code 1}</li>
 * </ul>
 */
public class OCRNoiseReducer implements CleansingProvider {

    // Matches 4-char year-like tokens that are mostly digits but may contain OCR noise letters
    private static final Pattern YEAR_LIKE = Pattern.compile("\\b([0-9IlSO]{4})\\b");

    @Override
    public String cleanse(String input) {
        if (input == null || input.isBlank()) {
            return input;
        }
        return YEAR_LIKE.matcher(input).replaceAll(mr -> {
            String token = mr.group(1);
            token = token.replace('S', '5');
            token = token.replace('O', '0');
            token = token.replace('l', '1');
            token = token.replace('I', '1');
            return token;
        });
    }
}
