package com.spexture.linkage_engine;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * View for {@code GET /v1/cost/month-to-date} (JSON) and {@code GET /v1/cost/month-to-date/page} (HTML).
 *
 * @param status {@code OK}, {@code DISABLED}, or {@code UNAVAILABLE}
 * @param tagFilterSummary human-readable filter, e.g. {@code App=linkage-engine}
 * @param amountUsd non-null only when status is {@code OK}
 * @param periodStartUtc first day of month (UTC), inclusive
 * @param periodEndExclusiveUtc first day of next month (UTC), exclusive upper bound for Cost Explorer
 * @param hint short UX note (lags, cost allocation tags, etc.)
 */
public record MonthToDateCostView(
        String status,
        String tagFilterSummary,
        String amountUsd,
        String periodStartUtc,
        String periodEndExclusiveUtc,
        String hint) {

    public Map<String, Object> toBody() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("status", status);
        m.put("tagFilterSummary", tagFilterSummary);
        if (amountUsd != null) {
            m.put("amountUsd", amountUsd);
        }
        if (periodStartUtc != null) {
            m.put("periodStartUtc", periodStartUtc);
        }
        if (periodEndExclusiveUtc != null) {
            m.put("periodEndExclusiveUtc", periodEndExclusiveUtc);
        }
        m.put("hint", hint);
        return m;
    }
}
