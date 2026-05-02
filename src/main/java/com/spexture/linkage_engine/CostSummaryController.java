package com.spexture.linkage_engine;

import java.util.Map;

import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.util.HtmlUtils;

/**
 * Read-only cost summary for UI (chord diagram) and operators.
 *
 * <ul>
 *   <li>{@code GET /v1/cost/month-to-date} — JSON
 *   <li>{@code GET /v1/cost/month-to-date/page} — HTML
 * </ul>
 */
@RestController
@RequestMapping("/v1/cost")
public class CostSummaryController {

    private final MonthlyTaggedCostService monthlyTaggedCostService;

    public CostSummaryController(MonthlyTaggedCostService monthlyTaggedCostService) {
        this.monthlyTaggedCostService = monthlyTaggedCostService;
    }

    @GetMapping("/month-to-date")
    public ResponseEntity<Map<String, Object>> monthToDate() {
        MonthToDateCostView view = monthlyTaggedCostService.monthToDate();
        return ResponseEntity.ok(view.toBody());
    }

    /**
     * Same data as {@link #monthToDate()} as a minimal HTML page for browsers and operators.
     */
    @GetMapping(value = "/month-to-date/page", produces = MediaType.TEXT_HTML_VALUE)
    public ResponseEntity<String> monthToDatePage() {
        MonthToDateCostView view = monthlyTaggedCostService.monthToDate();
        String html = renderMonthToDateHtml(view);
        return ResponseEntity.ok().contentType(MediaType.TEXT_HTML).body(html);
    }

    private static String renderMonthToDateHtml(MonthToDateCostView v) {
        String status = HtmlUtils.htmlEscape(v.status());
        String tagSummary = HtmlUtils.htmlEscape(nullToEmpty(v.tagFilterSummary()));
        String hint = HtmlUtils.htmlEscape(nullToEmpty(v.hint()));
        String periodStart = HtmlUtils.htmlEscape(nullToEmpty(v.periodStartUtc()));
        String periodEnd = HtmlUtils.htmlEscape(nullToEmpty(v.periodEndExclusiveUtc()));
        String amountBlock;
        if ("OK".equals(v.status()) && v.amountUsd() != null) {
            String amt = HtmlUtils.htmlEscape(v.amountUsd());
            amountBlock = "<p class=\"amount\"><span class=\"currency\">USD</span> " + amt + "</p>";
        } else {
            amountBlock = "<p class=\"amount muted\">No dollar total for this response.</p>";
        }
        String statusClass =
                switch (v.status()) {
                    case "OK" -> "ok";
                    case "DISABLED" -> "disabled";
                    default -> "unavailable";
                };
        String shell =
                """
                <!DOCTYPE html>
                <html lang="en">
                <head>
                  <meta charset="UTF-8" />
                  <meta name="viewport" content="width=device-width, initial-scale=1" />
                  <title>Month-to-date AWS cost — linkage-engine</title>
                  <style>
                    body { font-family: system-ui, sans-serif; background: #fafaf9; color: #1a1a18;
                           margin: 0; padding: 2rem 1.5rem; line-height: 1.5; }
                    main { max-width: 36rem; margin: 0 auto; }
                    h1 { font-size: 1.15rem; font-weight: 600; margin: 0 0 0.75rem; }
                    .status { display: inline-block; font-size: 0.75rem; font-weight: 600; text-transform: uppercase;
                              letter-spacing: 0.04em; padding: 0.2rem 0.55rem; border-radius: 4px; margin-bottom: 1rem; }
                    .status.ok { background: #e1f5ee; color: #085041; }
                    .status.disabled { background: #faeeda; color: #633806; }
                    .status.unavailable { background: #fcebeb; color: #8a1f1f; }
                    .amount { font-size: 1.75rem; font-weight: 600; margin: 0.25rem 0 1rem; font-variant-numeric: tabular-nums; }
                    .amount .currency { font-size: 0.55em; font-weight: 500; color: #6b6b63; margin-right: 0.25rem; }
                    .amount.muted { font-size: 1rem; font-weight: 400; color: #6b6b63; }
                    dl { margin: 0; font-size: 0.9rem; }
                    dt { color: #6b6b63; margin-top: 0.65rem; }
                    dd { margin: 0.15rem 0 0; }
                    .links { margin-top: 1.5rem; font-size: 0.85rem; }
                    .links a { color: #185fa5; }
                  </style>
                </head>
                <body>
                  <main>
                    <h1>Month-to-date AWS cost</h1>
                    <p class="status __STATUS_CLASS__">__STATUS__</p>
                    __AMOUNT_BLOCK__
                    <dl>
                      <dt>Tag filter</dt>
                      <dd>__TAG_SUMMARY__</dd>
                      <dt>UTC period (Cost Explorer)</dt>
                      <dd>[__PERIOD_START__, __PERIOD_END__)</dd>
                      <dt>Note</dt>
                      <dd>__HINT__</dd>
                    </dl>
                    <p class="links">
                      <a href="/v1/cost/month-to-date">JSON</a>
                      · <a href="/chord-diagram.html">Chord diagram</a>
                    </p>
                  </main>
                </body>
                </html>
                """;
        return shell.replace("__STATUS_CLASS__", statusClass)
                .replace("__STATUS__", status)
                .replace("__AMOUNT_BLOCK__", amountBlock)
                .replace("__TAG_SUMMARY__", tagSummary)
                .replace("__PERIOD_START__", periodStart)
                .replace("__PERIOD_END__", periodEnd)
                .replace("__HINT__", hint);
    }

    private static String nullToEmpty(String s) {
        return s == null ? "" : s;
    }
}
