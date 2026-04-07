package com.spexture.linkage_engine;

import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class LinkageEmbeddingTextTest {

    @Test
    void queryTextIncludesCoreFields() {
        String text = LinkageEmbeddingText.queryText(
            new LinkageResolveRequest("Mary", "Jones", 1900, "Chicago", null)
        );
        assertTrue(text.contains("Mary"));
        assertTrue(text.contains("Jones"));
        assertTrue(text.contains("1900"));
        assertTrue(text.contains("Chicago"));
    }
}
