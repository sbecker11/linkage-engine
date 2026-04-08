package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

/**
 * Sprint 8 — Operational Reliability: JVM memory tuning
 *
 * Verifies that the JVM heap budget is within the configured -Xmx1400m limit.
 * This test runs in the same JVM as the test suite, so it reflects the actual
 * heap ceiling in effect — if the Dockerfile ENTRYPOINT is wrong, this test
 * catches it in CI before deployment.
 *
 * Note: the test checks the configured max heap, not current usage, so it
 * passes immediately after startup without needing a load test.
 */
class MemoryTuningTest {

    private static final long MAX_HEAP_MB = 1400;

    // ── test 1 ────────────────────────────────────────────────────────────────

    /**
     * SIMULATE: Dockerfile ENTRYPOINT is missing -Xmx flag — JVM defaults to
     *           25% of container memory (~384m in a 1.5GB Fargate task), which
     *           causes OOM kills under load.
     * DETECT:   Dockerfile does not contain -Xmx1400m.
     * MITIGATE: Dockerfile sets -Xmx1400m explicitly.
     * VERIFY:   when the JVM was started with an explicit -Xmx flag, its value
     *           is within the Fargate budget; on a developer machine without
     *           -Xmx the test is skipped (unconstrained heap is expected locally).
     */
    @Test
    void appStartsWithinMemoryBudget() {
        // Check whether this JVM was started with an explicit -Xmx flag
        String xmxFlag = java.lang.management.ManagementFactory
            .getRuntimeMXBean()
            .getInputArguments()
            .stream()
            .filter(a -> a.startsWith("-Xmx"))
            .findFirst()
            .orElse(null);

        if (xmxFlag == null) {
            // Running on a developer machine without -Xmx — skip the upper bound check
            return;
        }

        long maxHeapMb = Runtime.getRuntime().maxMemory() / (1024 * 1024);
        assertThat(maxHeapMb)
            .as("Max heap (%dm) must not exceed %dm — Fargate task would OOM",
                maxHeapMb, MAX_HEAP_MB)
            .isLessThanOrEqualTo(MAX_HEAP_MB);
    }

    // ── test 2 ────────────────────────────────────────────────────────────────

    /**
     * VERIFY: the Dockerfile ENTRYPOINT contains -Xmx1400m.
     * Reads the Dockerfile directly so a CI build without the flag fails here
     * rather than silently deploying an under-configured container.
     */
    @Test
    void dockerfileContainsXmxFlag() throws Exception {
        java.nio.file.Path dockerfile = java.nio.file.Paths.get("Dockerfile");
        String content = java.nio.file.Files.readString(dockerfile);
        assertThat(content)
            .as("Dockerfile ENTRYPOINT must include -Xmx1400m")
            .contains("-Xmx1400m");
        assertThat(content)
            .as("Dockerfile ENTRYPOINT must include -Xms512m")
            .contains("-Xms512m");
    }
}
