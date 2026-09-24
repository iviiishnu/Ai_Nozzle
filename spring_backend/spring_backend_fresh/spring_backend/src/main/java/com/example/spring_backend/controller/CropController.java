package com.example.spring_backend.controller;

import java.io.IOException;

import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.multipart.MultipartFile;

import com.example.spring_backend.service.CropService;

@RestController
@RequestMapping("/api/crop")
public class CropController {

    private final CropService cropService;

    public CropController(CropService cropService) {
        this.cropService = cropService;
    }

    // Simple GET endpoint to check if API is running
    @GetMapping("/test")
    public String testApi() {
        return "Crop API is working!";
    }

    // Checks that the ML service behind this backend is reachable
    @GetMapping("/health")
    public ResponseEntity<String> health() {
        return cropService.health();
    }

    // POST endpoint to analyze crop image
    @PostMapping("/analyze")
    public ResponseEntity<String> analyzeCrop(@RequestParam("file") MultipartFile file) throws IOException {
        return cropService.analyze(file);
    }

    @ExceptionHandler(MaxUploadSizeExceededException.class)
    public ResponseEntity<String> tooLarge() {
        return ResponseEntity.status(413).contentType(MediaType.APPLICATION_JSON)
                .body("{\"error\":\"Image too large\"}");
    }
}
