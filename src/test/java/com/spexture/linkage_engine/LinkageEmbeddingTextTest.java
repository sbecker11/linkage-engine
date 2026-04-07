package com.spexture.linkage_engine;

import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

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

    @Test
    void toEmbeddingTextOmitsNullYear() {
        String text = LinkageEmbeddingText.toEmbeddingText("John", "Smith", null, "Boston");
        assertThat(text).doesNotContain("year=");
        assertThat(text).contains("Boston");
    }

    @Test
    void toEmbeddingTextOmitsBlankLocation() {
        String text = LinkageEmbeddingText.toEmbeddingText("John", "Smith", 1850, "  ");
        assertThat(text).doesNotContain("location=");
    }

    @Test
    void toEmbeddingTextOmitsNullLocation() {
        String text = LinkageEmbeddingText.toEmbeddingText("John", "Smith", 1850, null);
        assertThat(text).doesNotContain("location=");
    }

    @Test
    void queryTextForSearchRequestUsesRawQueryWhenPresent() {
        RecordSearchRequest req = new RecordSearchRequest("John", "Smith", 1850, "Boston", "raw query text");
        assertThat(LinkageEmbeddingText.queryText(req)).isEqualTo("raw query text");
    }

    @Test
    void queryTextForSearchRequestFallsBackToStructuredFields() {
        RecordSearchRequest req = new RecordSearchRequest("John", "Smith", 1850, "Boston", null);
        String text = LinkageEmbeddingText.queryText(req);
        assertThat(text).contains("John").contains("Smith").contains("1850").contains("Boston");
    }

    @Test
    void queryTextForSearchRequestFallsBackWhenBlankRawQuery() {
        RecordSearchRequest req = new RecordSearchRequest("John", "Smith", 1850, "Boston", "   ");
        String text = LinkageEmbeddingText.queryText(req);
        assertThat(text).contains("John");
    }
}
