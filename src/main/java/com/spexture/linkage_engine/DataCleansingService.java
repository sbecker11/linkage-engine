package com.spexture.linkage_engine;

import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Applies a fixed, ordered list of {@link CleansingProvider}s to a raw text string.
 */
public class DataCleansingService {

    private static final Logger log = LoggerFactory.getLogger(DataCleansingService.class);

    private final List<CleansingProvider> providers;

    public DataCleansingService(List<CleansingProvider> providers) {
        this.providers = List.copyOf(providers);
    }

    public String cleanse(String raw) {
        if (raw == null || raw.isBlank()) {
            return raw;
        }
        String result = raw;
        for (CleansingProvider provider : providers) {
            String before = result;
            result = provider.cleanse(result);
            if (!result.equals(before)) {
                log.debug("[{}] '{}' → '{}'", provider.getClass().getSimpleName(), before, result);
            }
        }
        return result;
    }
}
