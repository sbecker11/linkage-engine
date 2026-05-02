package com.spexture.linkage_engine;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.core.env.Environment;
import org.springframework.http.CacheControl;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Small JSON hints for static UI (e.g. {@code chord-diagram.html}) that cannot read Spring
 * profiles. Kept minimal to avoid coupling the SPA to server internals.
 */
@RestController
@RequestMapping("/v1/ui")
public class UiHintsController {

    private final Environment environment;

    public UiHintsController(Environment environment) {
        this.environment = environment;
    }

    /**
     * Chord diagram hides the month-to-date cost HTML link when profile {@code local} is
     * active; production and other profiles show it.
     */
    @GetMapping(value = "/features", produces = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<Map<String, Object>> features() {
        boolean local =
                Arrays.stream(environment.getActiveProfiles()).anyMatch("local"::equals);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("showCostMonthToDatePageLink", !local);
        return ResponseEntity.ok()
                .cacheControl(CacheControl.noStore())
                .body(body);
    }
}
