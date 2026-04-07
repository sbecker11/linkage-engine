package com.spexture.linkage_engine;

import java.util.Map;
import java.util.regex.Pattern;

/**
 * Expands common city abbreviations and informal short forms to their canonical names.
 * Replacements are word-boundary-aware and case-insensitive.
 */
public class LocationStandardizer implements CleansingProvider {

    private static final Map<String, String> ABBREVIATIONS = Map.ofEntries(
        Map.entry("philly",   "Philadelphia"),
        Map.entry("nyc",      "New York City"),
        Map.entry("ny",       "New York"),
        Map.entry("la",       "Los Angeles"),
        Map.entry("sf",       "San Francisco"),
        Map.entry("chi",      "Chicago"),
        Map.entry("bos",      "Boston"),
        Map.entry("dc",       "Washington DC"),
        Map.entry("atl",      "Atlanta"),
        Map.entry("hou",      "Houston"),
        Map.entry("phl",      "Philadelphia"),
        Map.entry("stl",      "St. Louis"),
        Map.entry("nola",     "New Orleans"),
        Map.entry("cincy",    "Cincinnati"),
        Map.entry("indy",     "Indianapolis")
    );

    @Override
    public String cleanse(String input) {
        if (input == null || input.isBlank()) {
            return input;
        }
        String result = input;
        for (Map.Entry<String, String> entry : ABBREVIATIONS.entrySet()) {
            Pattern pattern = Pattern.compile(
                "(?i)\\b" + Pattern.quote(entry.getKey()) + "\\b"
            );
            result = pattern.matcher(result).replaceAll(entry.getValue());
        }
        return result;
    }
}
