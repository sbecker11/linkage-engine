package com.spexture.linkage_engine;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.core.MethodParameter;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpInputMessage;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.validation.BeanPropertyBindingResult;
import org.springframework.validation.FieldError;
import org.springframework.web.bind.MethodArgumentNotValidException;

class ApiExceptionHandlerTest {

    @Test
    void handleValidationReturnsBadRequestWithDetails() throws Exception {
        LinkageResolveRequest target = new LinkageResolveRequest("", "", 1850, "Boston");
        BeanPropertyBindingResult binding = new BeanPropertyBindingResult(target, "request");
        binding.addError(new FieldError("request", "givenName", "givenName is required"));
        binding.addError(new FieldError("request", "familyName", "familyName is required"));

        MethodParameter parameter = new MethodParameter(
            LinkageController.class.getDeclaredMethod("resolve", LinkageResolveRequest.class), 0
        );
        MethodArgumentNotValidException ex = new MethodArgumentNotValidException(parameter, binding);

        ApiExceptionHandler handler = new ApiExceptionHandler();
        ResponseEntity<?> response = handler.handleValidation(ex);

        assertEquals(400, response.getStatusCode().value());
        Map<?, ?> body = (Map<?, ?>) response.getBody();
        assertEquals("Validation failed.", body.get("error"));
        String details = body.get("details").toString();
        assertTrue(details.contains("givenName"));
        assertTrue(details.contains("familyName"));
    }

    @Test
    void handleMalformedJsonReturnsBadRequest() {
        ApiExceptionHandler handler = new ApiExceptionHandler();
        HttpInputMessage inputMessage = new HttpInputMessage() {
            @Override
            public java.io.InputStream getBody() {
                return java.io.InputStream.nullInputStream();
            }

            @Override
            public HttpHeaders getHeaders() {
                return HttpHeaders.EMPTY;
            }
        };
        ResponseEntity<?> response = handler.handleMalformedJson(
            new HttpMessageNotReadableException("bad json", inputMessage)
        );

        assertEquals(400, response.getStatusCode().value());
        Map<?, ?> body = (Map<?, ?>) response.getBody();
        assertEquals("Malformed JSON request body.", body.get("error"));
    }
}
