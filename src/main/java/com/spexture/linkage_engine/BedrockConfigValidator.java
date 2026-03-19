package com.spexture.linkage_engine;

import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class BedrockConfigValidator implements ApplicationRunner {

    private final Environment environment;

    public BedrockConfigValidator(Environment environment) {
        this.environment = environment;
    }

    @Override
    public void run(ApplicationArguments args) {
        String chatProvider = environment.getProperty("spring.ai.model.chat", "");
        if (!"bedrock-converse".equalsIgnoreCase(chatProvider)) {
            return;
        }

        String modelId = environment.getProperty("spring.ai.bedrock.converse.chat.options.model", "");
        if (!StringUtils.hasText(modelId)) {
            throw new IllegalStateException(
                "Missing Bedrock model id. Set BEDROCK_MODEL_ID (or spring.ai.bedrock.converse.chat.options.model) before startup."
            );
        }
    }
}
