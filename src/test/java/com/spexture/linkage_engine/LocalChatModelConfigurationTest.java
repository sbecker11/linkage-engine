package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class LocalChatModelConfigurationTest {

    private final ApplicationContextRunner runner = new ApplicationContextRunner()
        .withUserConfiguration(LocalChatModelConfiguration.class)
        .withPropertyValues("spring.profiles.active=local");

    @Test
    void localProfileRegistersFallbackChatModel() {
        runner.run(ctx -> {
            assertThat(ctx).hasSingleBean(ChatModel.class);
            var response = ctx.getBean(ChatModel.class).call(new Prompt("hello"));
            String out = response.getResult().getOutput().getText();
            assertThat(out).startsWith("[LOCAL] Deterministic summary for:");
        });
    }
}
