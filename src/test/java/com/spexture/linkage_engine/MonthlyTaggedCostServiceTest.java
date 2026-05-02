package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class MonthlyTaggedCostServiceTest {

    @Test
    void disabled_returnsDisabledWithoutAws() {
        MonthlyTaggedCostService svc = new MonthlyTaggedCostService(false, "App", "linkage-engine");
        MonthToDateCostView v = svc.monthToDate();
        assertThat(v.status()).isEqualTo("DISABLED");
        assertThat(v.tagFilterSummary()).isEqualTo("App=linkage-engine");
        assertThat(v.amountUsd()).isNull();
        svc.shutdown();
    }
}
