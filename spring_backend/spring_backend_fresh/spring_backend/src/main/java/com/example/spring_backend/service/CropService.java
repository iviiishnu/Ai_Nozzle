package com.example.spring_backend.service;

import org.springframework.core.io.ByteArrayResource;
import org.springframework.http.*;
import org.springframework.stereotype.Service;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestTemplate;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;

@Service
public class CropService {

    private final RestTemplate restTemplate = new RestTemplate();

    public String sendImageToAI(MultipartFile file) throws IOException {
        String aiUrl = "http://127.0.0.1:5010/api/crop/analyze";

        // Wrap file in a ByteArrayResource so RestTemplate knows it's a file
        ByteArrayResource fileResource = new ByteArrayResource(file.getBytes()) {
            @Override
            public String getFilename() {
                return file.getOriginalFilename(); // Return actual filename
            }
        };

        // Create multipart form data body
        MultiValueMap<String, Object> body = new LinkedMultiValueMap<>();
        body.add("file", fileResource);

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.MULTIPART_FORM_DATA);

        HttpEntity<MultiValueMap<String, Object>> requestEntity = new HttpEntity<>(body, headers);

        ResponseEntity<String> response = restTemplate.postForEntity(aiUrl, requestEntity, String.class);

        return response.getBody();
    }
}
