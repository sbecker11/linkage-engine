package com.spexture.linkage_engine;

import java.util.List;

import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
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
        @Value("${spring.ai.bedrock.titan.embedding.model:bedrock-titan}") String embeddingModelId
    ) {
        return new RecordIngestService(
            recordMutator.getIfAvailable(),
            embeddingModel.getIfAvailable(),
            recordEmbeddingStore.getIfAvailable(),
            embeddingModelId,
            dataCleansingService
        );
    }

    @Bean
    RecordIngestController recordIngestController(RecordIngestPort recordIngestPort) {
        return new RecordIngestController(recordIngestPort);
    }

}
