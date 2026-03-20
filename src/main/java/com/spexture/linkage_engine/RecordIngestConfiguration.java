package com.spexture.linkage_engine;

import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class RecordIngestConfiguration {

    @Bean
    @ConditionalOnBean(LinkageRecordMutator.class)
    RecordIngestPort recordIngestPort(
        LinkageRecordMutator recordMutator,
        ObjectProvider<EmbeddingModel> embeddingModel,
        ObjectProvider<RecordEmbeddingStore> recordEmbeddingStore,
        @Value("${spring.ai.bedrock.titan.embedding.model:bedrock-titan}") String embeddingModelId
    ) {
        return new RecordIngestService(
            recordMutator,
            embeddingModel.getIfAvailable(),
            recordEmbeddingStore.getIfAvailable(),
            embeddingModelId
        );
    }

    @Bean
    @ConditionalOnBean(RecordIngestPort.class)
    RecordIngestController recordIngestController(RecordIngestPort recordIngestPort) {
        return new RecordIngestController(recordIngestPort);
    }

}
