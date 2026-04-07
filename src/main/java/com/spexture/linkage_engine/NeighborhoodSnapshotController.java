package com.spexture.linkage_engine;

import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/v1/context")
public class NeighborhoodSnapshotController {

    private static final Logger log = LoggerFactory.getLogger(NeighborhoodSnapshotController.class);
    private static final int YEAR_TOLERANCE = 5;
    private static final int TOP_NAMES = 5;

    private final LinkageRecordStore linkageRecordStore;
    private final ChatModel chatModel;
    private final boolean semanticLlmEnabled;

    @Autowired
    public NeighborhoodSnapshotController(
        LinkageRecordStore linkageRecordStore,
        @Autowired(required = false) ChatModel chatModel,
        @Value("${linkage.semantic.llm.enabled:true}") boolean semanticLlmEnabled
    ) {
        this.linkageRecordStore = linkageRecordStore;
        this.chatModel = chatModel;
        this.semanticLlmEnabled = semanticLlmEnabled;
    }

    @GetMapping("/neighborhood-snapshot")
    public ResponseEntity<NeighborhoodSnapshot> snapshot(
        @RequestParam(name = "location") String location,
        @RequestParam(name = "year") int year
    ) {
        List<CandidateRecord> records =
            linkageRecordStore.findByLocationAndYearRange(location, year, YEAR_TOLERANCE);

        log.info("[neighborhood-snapshot] location={} year={} records={}", location, year, records.size());

        List<String> commonNames = topNames(records);
        int yearMin = records.stream().mapToInt(r -> r.year() == null ? year : r.year()).min().orElse(year);
        int yearMax = records.stream().mapToInt(r -> r.year() == null ? year : r.year()).max().orElse(year);

        String summary = buildSummary(location, year, records, commonNames);
        boolean llmUsed = false;

        if (semanticLlmEnabled && chatModel != null && !records.isEmpty()) {
            try {
                String prompt = buildPrompt(location, year, records, commonNames);
                summary = chatModel.call(prompt);
                llmUsed = true;
                log.debug("[neighborhood-snapshot] LLM summary produced ({} chars)", summary.length());
            } catch (RuntimeException ex) {
                log.warn("[neighborhood-snapshot] ChatModel failed, using deterministic: {}", ex.getMessage());
            }
        }

        return ResponseEntity.ok(new NeighborhoodSnapshot(
            location, year, records.size(), commonNames, yearMin, yearMax, summary, llmUsed
        ));
    }

    private List<String> topNames(List<CandidateRecord> records) {
        return records.stream()
            .collect(Collectors.groupingBy(
                r -> r.givenName() + " " + r.familyName(),
                Collectors.counting()
            ))
            .entrySet().stream()
            .sorted(Map.Entry.<String, Long>comparingByValue().reversed())
            .limit(TOP_NAMES)
            .map(Map.Entry::getKey)
            .toList();
    }

    private String buildSummary(String location, int year, List<CandidateRecord> records,
                                 List<String> commonNames) {
        if (records.isEmpty()) {
            return "No records found near " + location + " around " + year + ".";
        }
        return String.format(
            "%d records found near %s around %d. Common names: %s.",
            records.size(), location, year,
            commonNames.isEmpty() ? "none" : String.join(", ", commonNames)
        );
    }

    private String buildPrompt(String location, int year, List<CandidateRecord> records,
                                List<String> commonNames) {
        return String.format(
            """
            You are a genealogical research assistant. Provide a brief contextual summary \
            (2-3 sentences) for a researcher looking at records near %s around %d.
            There are %d records in this area and time window.
            Common names found: %s.
            Focus on what this location and era would have been like historically.
            """,
            location, year, records.size(),
            commonNames.isEmpty() ? "none" : String.join(", ", commonNames)
        );
    }
}
