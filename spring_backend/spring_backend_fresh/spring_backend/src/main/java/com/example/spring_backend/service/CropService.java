package com.example.spring_backend.service;

import java.io.IOException;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Service;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.HttpStatusCodeException;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestTemplate;
import org.springframework.web.multipart.MultipartFile;

/**
 * Forwards images to the Python ML service and relays its JSON response.
 * The ML service URL comes from application.properties (AI_SERVICE_URL env).
 */
@Service
public class CropService {

    private final RestTemplate restTemplate;
    private final String aiServiceUrl;

    public CropService(RestTemplate restTemplate, @Value("${ai.service.url}") String aiServiceUrl) {
        this.restTemplate = restTemplate;
        this.aiServiceUrl = aiServiceUrl.replaceAll("/+$", "");
    }

    public ResponseEntity<String> analyze(MultipartFile file) throws IOException {
        ByteArrayResource fileResource = new ByteArrayResource(file.getBytes()) {
            @Override
            public String getFilename() {
                String name = file.getOriginalFilename();
                return (name == null || name.isBlank()) ? "image.jpg" : name;
            }
        };

        MultiValueMap<String, Object> body = new LinkedMultiValueMap<>();
        body.add("file", fileResource);

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.MULTIPART_FORM_DATA);

        return forward(() -> restTemplate.postForEntity(
                aiServiceUrl + "/api/crop/analyze", new HttpEntity<>(body, headers), String.class));
    }

    public ResponseEntity<String> health() {
        return forward(() -> restTemplate.getForEntity(aiServiceUrl + "/health", String.class));
    }

    /** Runs the call and maps ML-service errors to JSON responses with the right status. */
    private ResponseEntity<String> forward(java.util.function.Supplier<ResponseEntity<String>> call) {
        try {
            ResponseEntity<String> response = call.get();
            return json(response.getStatusCode().value(), response.getBody());
        } catch (HttpStatusCodeException e) {
            // e.g. 400 "No leaf detected" — pass the ML service's JSON through unchanged
            return json(e.getStatusCode().value(), e.getResponseBodyAsString());
        } catch (ResourceAccessException e) {
            return json(HttpStatus.SERVICE_UNAVAILABLE.value(),
                    "{\"error\":\"ML service unavailable\",\"details\":\"" + escape(e.getMessage()) + "\"}");
        }
    }

    private static ResponseEntity<String> json(int status, String body) {
        return ResponseEntity.status(status).contentType(MediaType.APPLICATION_JSON).body(body);
    }

    private static String escape(String s) {
        return s == null ? "" : s.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
