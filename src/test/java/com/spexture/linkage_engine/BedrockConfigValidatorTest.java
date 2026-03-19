package com.spexture.linkage_engine;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;
import org.springframework.core.env.Environment;
import org.springframework.mock.env.MockEnvironment;

class BedrockConfigValidatorTest {

    @Test
    void runDoesNothingWhenProviderIsNotBedrock() {
        Environment env = new MockEnvironment()
            .withProperty("spring.ai.model.chat", "none");
        BedrockConfigValidator validator = new BedrockConfigValidator(env);

        assertDoesNotThrow(() -> validator.run(null));
    }

    @Test
    void runThrowsWhenBedrockProviderHasNoModelId() {
        Environment env = new MockEnvironment()
            .withProperty("spring.ai.model.chat", "bedrock-converse")
            .withProperty("spring.ai.bedrock.converse.chat.options.model", "");
        BedrockConfigValidator validator = new BedrockConfigValidator(env);

        assertThrows(IllegalStateException.class, () -> validator.run(null));
    }

    @Test
    void runSucceedsWhenBedrockProviderAndModelIdPresent() {
        Environment env = new MockEnvironment()
            .withProperty("spring.ai.model.chat", "bedrock-converse")
            .withProperty("spring.ai.bedrock.converse.chat.options.model", "us.amazon.nova-lite-v1:0");
        BedrockConfigValidator validator = new BedrockConfigValidator(env);

        assertDoesNotThrow(() -> validator.run(null));
    }
}
