package com.spexture.linkage_engine;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.util.List;

import org.junit.jupiter.api.Test;
import org.mockito.InOrder;

class DataCleansingServiceTest {

    @Test
    void appliesProvidersInOrder() {
        CleansingProvider first = mock(CleansingProvider.class);
        CleansingProvider second = mock(CleansingProvider.class);
        when(first.cleanse("raw")).thenReturn("step1");
        when(second.cleanse("step1")).thenReturn("step2");

        DataCleansingService service = new DataCleansingService(List.of(first, second));
        String result = service.cleanse("raw");

        assertThat(result).isEqualTo("step2");
        InOrder order = inOrder(first, second);
        order.verify(first).cleanse("raw");
        order.verify(second).cleanse("step1");
    }

    @Test
    void endToEndDirtyRecord() {
        DataCleansingService service = new DataCleansingService(List.of(
            new OCRNoiseReducer(),
            new LocationStandardizer()
        ));
        // "18S0" → OCR fix → "1850"; "Philly" → location expand → "Philadelphia"
        String result = service.cleanse("John Smith, Philly, 18S0");
        assertThat(result).isEqualTo("John Smith, Philadelphia, 1850");
    }

    @Test
    void returnsNullForNullInput() {
        DataCleansingService service = new DataCleansingService(List.of(new OCRNoiseReducer()));
        assertThat(service.cleanse(null)).isNull();
    }

    @Test
    void returnsBlankForBlankInput() {
        DataCleansingService service = new DataCleansingService(List.of(new OCRNoiseReducer()));
        assertThat(service.cleanse("   ")).isEqualTo("   ");
    }
}
