package com.spexture.linkage_engine;

import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Map;

import org.springframework.ai.chat.model.ChatModel;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Request body for POST /api/dateAtLocation: JSON like {"location": "Chicago"} */
record DateTimeAtLocationRequest(String location) {}

@RestController
public class ChatController {

    private final ChatModel chatModel;

    public ChatController(ChatModel chatModel) {
        this.chatModel = chatModel;
    }

    @GetMapping("/api/ask")
    ResponseEntity<?> ask(@RequestParam(name = "q", defaultValue = "Hello!") String q) {
        try {
            return ResponseEntity.ok(chatModel.call(q));
        } catch (Exception ex) {
            return chatFailure("Unable to get response from model.");
        }
    }
    // example curl POST request:
    // curl -X POST "http://localhost:8080/api/dateTimeAtLocation" -H "Content-Type: application/json" -d '{"location":"Chicago"}'
    @PostMapping("/api/dateTimeAtLocation")
    ResponseEntity<?> askDateTimeAtLocation(@RequestBody DateTimeAtLocationRequest request) {
        try {
            String defaultLocation = "Lehi, Utah, USA";
            ZoneId defaultZone = ZoneId.of("America/Denver"); // Lehi, Utah
            String defaultLocationDateTime = ZonedDateTime.now(defaultZone).format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm z"));
            String location = request != null && request.location() != null && !request.location().isBlank()
                ? request.location() : defaultLocation;
            String question = "What date and time is it at " + location + "?";
            String context = "The current date and time at " + defaultLocation + " is " + defaultLocationDateTime + ".";
            String additionalContext = "Use this exact date and time; do not change the year.";
            String plainTextInstructions = "Reply with plain text only; do not use Markdown or bold formatting.";
            String verboseInstructions = "Be verbose and detailed in your response.";
            String promptWithContext = String.join(" ",
                context, additionalContext, plainTextInstructions, verboseInstructions, question);
            return ResponseEntity.ok(chatModel.call(promptWithContext));
        } catch (Exception ex) {
            return chatFailure("Unable to get date/time response from model.");
        }
    }

    private ResponseEntity<Map<String, String>> chatFailure(String message) {
        return ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(Map.of("error", message));
    }
}
