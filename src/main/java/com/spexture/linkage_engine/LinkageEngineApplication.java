package com.spexture.linkage_engine;

import io.github.cdimascio.dotenv.Dotenv;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class LinkageEngineApplication {

	public static void main(String[] args) {
		// Load .env from project root into system properties so ${OPENAI_API_KEY} etc. resolve in application.properties
		Dotenv dotenv = Dotenv.configure().ignoreIfMissing().load();
		dotenv.entries().forEach(e -> System.setProperty(e.getKey(), e.getValue()));
		SpringApplication.run(LinkageEngineApplication.class, args);
	}

}
