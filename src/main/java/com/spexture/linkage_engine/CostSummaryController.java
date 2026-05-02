package com.spexture.linkage_engine;

import java.util.Map;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Read-only cost summary for UI (chord diagram) and operators.
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
}
