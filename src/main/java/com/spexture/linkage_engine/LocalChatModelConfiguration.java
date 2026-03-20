package com.spexture.linkage_engine;

import java.util.List;

import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.ai.chat.model.ChatResponse;
import org.springframework.ai.chat.model.Generation;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;

/**
 * Provides a {@link ChatModel} under the {@code local} profile so the app can start with {@code spring.ai.model.chat=none}.
 */
@Configuration
@Profile("local")
public class LocalChatModelConfiguration {

    @Bean
    ChatModel localFallbackChatModel() {
        return new ChatModel() {
            @Override
            public ChatResponse call(Prompt prompt) {
                String contents = prompt.getContents();
                String snippet = contents.length() > 200 ? contents.substring(0, 200) + "..." : contents;
                return new ChatResponse(List.of(new Generation(new AssistantMessage(
                    "Local profile (no Bedrock): echo — " + snippet))));
            }
        };
    }
}
