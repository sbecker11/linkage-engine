package com.spexture.linkage_engine;

import java.util.Map;

import jakarta.validation.Valid;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/v1/linkage")
@ConditionalOnBean(JdbcTemplate.class)
public class LinkageController {

    private final LinkageResolver linkageResolver;

    public LinkageController(LinkageResolver linkageResolver) {
        this.linkageResolver = linkageResolver;
    }

    @PostMapping("/resolve")
    ResponseEntity<?> resolve(@Valid @RequestBody LinkageResolveRequest request) {
        try {
            return ResponseEntity.ok(linkageResolver.resolve(request));
        } catch (Exception ex) {
            return ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(Map.of(
                "error", "Unable to score linkage candidates with model."
            ));
        }
    }
}
