package com.spexture.linkage_engine;

import java.util.Map;

import org.springframework.boot.actuate.health.CompositeHealth;
import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthComponent;
import org.springframework.boot.actuate.health.HealthEndpoint;
import org.springframework.http.CacheControl;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.util.HtmlUtils;

/**
 * Browser page for the Spring Boot Actuator health endpoint.
 *
 * {@code GET /actuator/health} returns {@code application/vnd.spring-boot.actuator.v3+json},
 * which browsers download or leave blank instead of showing a page. This HTML view uses the
 * same {@link HealthEndpoint} data.
 */
@RestController
public class ActuatorHealthPageController {

    private final HealthEndpoint healthEndpoint;

    public ActuatorHealthPageController(HealthEndpoint healthEndpoint) {
        this.healthEndpoint = healthEndpoint;
    }

    @GetMapping(value = "/v1/health/page", produces = MediaType.TEXT_HTML_VALUE)
    public ResponseEntity<String> page() {
        HealthComponent health = healthEndpoint.health();
        String status = health.getStatus().getCode();
        String statusClass = "UP".equals(status) ? "ok" : "down";
        String html = render(status, statusClass, componentRows(health));
        return ResponseEntity.ok()
                .contentType(MediaType.TEXT_HTML)
                .cacheControl(CacheControl.noStore())
                .body(html);
    }

    private static String componentRows(HealthComponent health) {
        StringBuilder rows = new StringBuilder();
        if (health instanceof CompositeHealth composite) {
            Map<String, HealthComponent> components = composite.getComponents();
            if (components != null) {
                for (Map.Entry<String, HealthComponent> entry : components.entrySet()) {
                    appendRow(rows, entry.getKey(), entry.getValue());
                }
            }
        } else if (health instanceof Health single) {
            appendRow(rows, "health", single);
        }
        if (rows.isEmpty()) {
            rows.append("<tr><td colspan=\"3\">No component details.</td></tr>");
        }
        return rows.toString();
    }

    private static void appendRow(StringBuilder rows, String name, HealthComponent component) {
        String status = component.getStatus().getCode();
        String details = "";
        if (component instanceof Health health && health.getDetails() != null && !health.getDetails().isEmpty()) {
            details = formatDetails(health.getDetails());
        }
        rows.append("<tr><td>")
                .append(HtmlUtils.htmlEscape(name))
                .append("</td><td class=\"")
                .append("UP".equals(status) ? "ok" : "down")
                .append("\">")
                .append(HtmlUtils.htmlEscape(status))
                .append("</td><td>")
                .append(HtmlUtils.htmlEscape(details))
                .append("</td></tr>");
        if (component instanceof CompositeHealth nested) {
            Map<String, HealthComponent> children = nested.getComponents();
            if (children != null) {
                for (Map.Entry<String, HealthComponent> entry : children.entrySet()) {
                    appendRow(rows, name + "." + entry.getKey(), entry.getValue());
                }
            }
        }
    }

    private static String formatDetails(Map<String, Object> details) {
        StringBuilder text = new StringBuilder();
        for (Map.Entry<String, Object> entry : details.entrySet()) {
            if (!text.isEmpty()) {
                text.append("; ");
            }
            text.append(entry.getKey()).append("=").append(stringify(entry.getValue()));
        }
        return text.toString();
    }

    private static String stringify(Object value) {
        if (!(value instanceof Map<?, ?> map)) {
            return String.valueOf(value);
        }
        StringBuilder text = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<?, ?> entry : map.entrySet()) {
            if (!first) {
                text.append(", ");
            }
            first = false;
            text.append(entry.getKey()).append("=").append(stringify(entry.getValue()));
        }
        text.append("}");
        return text.toString();
    }

    private static String render(String status, String statusClass, String rows) {
        String shell =
                """
                <!DOCTYPE html>
                <html lang="en">
                <head>
                  <meta charset="UTF-8" />
                  <meta name="viewport" content="width=device-width, initial-scale=1" />
                  <title>Actuator health — linkage-engine</title>
                  <style>
                    body { font-family: system-ui, sans-serif; background: #fafaf9; color: #1a1a18;
                           margin: 0; padding: 2rem 1.5rem; line-height: 1.5; }
                    main { max-width: 44rem; margin: 0 auto; }
                    h1 { font-size: 1.15rem; font-weight: 600; margin: 0 0 0.75rem; }
                    .status { display: inline-block; font-size: 0.75rem; font-weight: 600; text-transform: uppercase;
                              letter-spacing: 0.04em; padding: 0.2rem 0.55rem; border-radius: 4px; margin-bottom: 1rem; }
                    .status.ok { background: #e1f5ee; color: #085041; }
                    .status.down { background: #fcebeb; color: #8a1f1f; }
                    table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
                    th, td { text-align: left; vertical-align: top; padding: 0.4rem 0.6rem 0.4rem 0;
                             border-bottom: 1px solid #e4e4e0; }
                    th { color: #6b6b63; font-weight: 500; font-size: 0.75rem; text-transform: uppercase;
                         letter-spacing: 0.04em; }
                    td.ok { color: #085041; font-weight: 600; }
                    td.down { color: #8a1f1f; font-weight: 600; }
                    .links { margin-top: 1.5rem; font-size: 0.85rem; }
                    .links a { color: #185fa5; }
                  </style>
                </head>
                <body>
                  <main>
                    <h1>Actuator health</h1>
                    <p class="status __STATUS_CLASS__">__STATUS__</p>
                    <table>
                      <thead><tr><th>Component</th><th>Status</th><th>Details</th></tr></thead>
                      <tbody>
                        __ROWS__
                      </tbody>
                    </table>
                    <p class="links">
                      <a href="/actuator/health">JSON</a>
                      · <a href="/chord-diagram.html">Chord diagram</a>
                    </p>
                  </main>
                </body>
                </html>
                """;
        return shell.replace("__STATUS_CLASS__", statusClass)
                .replace("__STATUS__", HtmlUtils.htmlEscape(status))
                .replace("__ROWS__", rows);
    }
}
