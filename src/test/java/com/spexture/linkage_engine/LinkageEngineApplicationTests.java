package com.spexture.linkage_engine;

import org.junit.jupiter.api.Test;
import org.springframework.ai.openai.OpenAiChatModel;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;

@SpringBootTest
class LinkageEngineApplicationTests {

	@MockBean
	OpenAiChatModel openAiChatModel;

	@Test
	void contextLoads() {
		when(openAiChatModel.call(anyString())).thenReturn("mock response");
	}

}
