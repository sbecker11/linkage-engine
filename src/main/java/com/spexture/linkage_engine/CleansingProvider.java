package com.spexture.linkage_engine;

/**
 * Single-responsibility text cleansing step applied in order by {@link DataCleansingService}.
 */
public interface CleansingProvider {

    String cleanse(String input);
}
