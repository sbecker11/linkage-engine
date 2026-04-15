package com.spexture.linkage_engine;

import java.util.List;

import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class RecordIngestConfiguration {

    @Bean
    DataCleansingService dataCleansingService() {
        return new DataCleansingService(List.of(
            new OCRNoiseReducer(),
            new LocationStandardizer()
        ));
    }

    @Bean
    RecordIngestPort recordIngestPort(
        ObjectProvider<LinkageRecordMutator> recordMutator,
        ObjectProvider<EmbeddingModel> embeddingModel,
        ObjectProvider<RecordEmbeddingStore> recordEmbeddingStore,
        DataCleansingService dataCleansingService,
        ObjectProvider<IngestHealthService> ingestHealthService,
        @Value("${spring.ai.bedrock.titan.embedding.model:bedrock-titan}") String embeddingModelId
    ) {
        return new RecordIngestService(
            recordMutator.getIfAvailable(),
            embeddingModel.getIfAvailable(),
            recordEmbeddingStore.getIfAvailable(),
            embeddingModelId,
            dataCleansingService,
            ingestHealthService
        );
    }

    @Bean
    RecordIngestController recordIngestController(RecordIngestPort recordIngestPort) {
        return new RecordIngestController(recordIngestPort);
    }

    /**
     * Sprint 9 — register ApiKeyFilter only on /v1/records.
     * Key is read from INGEST_API_KEY env var (blank = filter disabled for local dev).
     */
    @Bean
    FilterRegistrationBean<ApiKeyFilter> apiKeyFilterRegistration(
            @Value("${ingest.api-key:}") String apiKey) {
        FilterRegistrationBean<ApiKeyFilter> reg = new FilterRegistrationBean<>();
        reg.setFilter(new ApiKeyFilter(apiKey));
        reg.addUrlPatterns("/v1/records", "/v1/records/*");
        reg.setName("apiKeyFilter");
        reg.setOrder(1);
        return reg;
    }
}
