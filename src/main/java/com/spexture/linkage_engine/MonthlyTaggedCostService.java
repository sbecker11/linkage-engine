package com.spexture.linkage_engine;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.ZoneOffset;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import jakarta.annotation.PreDestroy;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.costexplorer.CostExplorerClient;
import software.amazon.awssdk.services.costexplorer.model.DateInterval;
import software.amazon.awssdk.services.costexplorer.model.Expression;
import software.amazon.awssdk.services.costexplorer.model.GetCostAndUsageRequest;
import software.amazon.awssdk.services.costexplorer.model.GetCostAndUsageResponse;
import software.amazon.awssdk.services.costexplorer.model.Granularity;
import software.amazon.awssdk.services.costexplorer.model.MetricValue;
import software.amazon.awssdk.services.costexplorer.model.ResultByTime;
import software.amazon.awssdk.services.costexplorer.model.TagValues;

/**
 * Fetches current calendar month (UTC) unblended cost from AWS Cost Explorer,
 * filtered by a user-defined cost allocation tag (default {@code App=linkage-engine}).
 *
 * <p>Requires: Cost Explorer enabled on the account, the tag activated as a cost allocation tag
 * in Billing, and IAM {@code ce:GetCostAndUsage} on the runtime role. The Cost Explorer API
 * endpoint is {@code us-east-1} regardless of where workloads run.
 */
@Service
public class MonthlyTaggedCostService {

    private static final Logger log = LoggerFactory.getLogger(MonthlyTaggedCostService.class);

    private final boolean enabled;
    private final String tagKey;
    private final String tagValue;

    private volatile CostExplorerClient client;

    public MonthlyTaggedCostService(
            @Value("${linkage.cost.enabled:false}") boolean enabled,
            @Value("${linkage.cost.tag-key:App}") String tagKey,
            @Value("${linkage.cost.tag-value:linkage-engine}") String tagValue) {
        this.enabled = enabled;
        this.tagKey = tagKey;
        this.tagValue = tagValue;
    }

    public MonthToDateCostView monthToDate() {
        String summary = tagKey + "=" + tagValue;
        if (!enabled) {
            return new MonthToDateCostView(
                    "DISABLED",
                    summary,
                    null,
                    null,
                    null,
                    "Set LINKAGE_COST_ENABLED=true on the task to query Cost Explorer.");
        }

        LocalDate todayUtc = LocalDate.now(ZoneOffset.UTC);
        LocalDate monthStart = todayUtc.withDayOfMonth(1);
        LocalDate monthEndExclusive = monthStart.plusMonths(1);
        String start = monthStart.toString();
        String end = monthEndExclusive.toString();

        Expression tagFilter = Expression.builder()
                .tags(TagValues.builder().key(tagKey).values(tagValue).build())
                .build();

        GetCostAndUsageRequest request = GetCostAndUsageRequest.builder()
                .timePeriod(DateInterval.builder().start(start).end(end).build())
                .granularity(Granularity.MONTHLY)
                .metrics("UnblendedCost")
                .filter(tagFilter)
                .build();

        try {
            GetCostAndUsageResponse response = client().getCostAndUsage(request);
            BigDecimal total = BigDecimal.ZERO;
            for (ResultByTime rbt : response.resultsByTime()) {
                if (!rbt.hasTotal()) {
                    continue;
                }
                MetricValue mv = rbt.total().get("UnblendedCost");
                if (mv != null && mv.amount() != null && !mv.amount().isBlank()) {
                    total = total.add(new BigDecimal(mv.amount()));
                }
            }
            String amount = total.setScale(2, RoundingMode.HALF_UP).toPlainString();
            return new MonthToDateCostView(
                    "OK",
                    summary,
                    amount,
                    start,
                    end,
                    "UnblendedCost in USD (UTC month). Cost Explorer can lag up to ~24 hours. "
                            + "Tag must be an activated cost allocation tag.");
        } catch (Exception e) {
            log.warn("Cost Explorer month-to-date query failed: {}", e.toString());
            return new MonthToDateCostView(
                    "UNAVAILABLE",
                    summary,
                    null,
                    start,
                    end,
                    shortHint(e));
        }
    }

    private static String shortHint(Throwable e) {
        String m = e.getMessage();
        if (m == null || m.isBlank()) {
            return e.getClass().getSimpleName();
        }
        return m.length() > 220 ? m.substring(0, 217) + "…" : m;
    }

    private CostExplorerClient client() {
        CostExplorerClient c = client;
        if (c == null) {
            synchronized (this) {
                c = client;
                if (c == null) {
                    c = CostExplorerClient.builder()
                            .region(Region.US_EAST_1)
                            .build();
                    client = c;
                }
            }
        }
        return c;
    }

    @PreDestroy
    public void shutdown() {
        CostExplorerClient c = client;
        if (c != null) {
            c.close();
            client = null;
        }
    }
}
