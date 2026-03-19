package com.spexture.linkage_engine;

import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;

@SpringBootTest
class LinkageEngineApplicationTests {

	@MockBean
	ChatModel chatModel;
	@MockBean
	LinkageRecordStore linkageRecordStore;

	@Test
	void contextLoads() {
		when(chatModel.call(anyString())).thenReturn("mock response");
	}

}
