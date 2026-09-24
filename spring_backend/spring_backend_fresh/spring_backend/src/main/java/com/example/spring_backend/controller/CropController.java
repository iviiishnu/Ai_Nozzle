package com.example.spring_backend.controller;

import com.example.spring_backend.service.CropService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

@RestController
@RequestMapping("/api/crop")
public class CropController {

    @Autowired
    private CropService cropService;

    // Simple GET endpoint to check if API is running
    @GetMapping("/test")
    public String testApi() {
        return "Crop API is working!";
    }

    // POST endpoint to analyze crop image
    @PostMapping("/analyze")
    public ResponseEntity<String> analyzeCrop(@RequestParam MultipartFile file) {
        try {
            String result = cropService.sendImageToAI(file);
            return ResponseEntity.ok(result);
        } catch (Exception e) {
            return ResponseEntity.status(500).body("Error: " + e.getMessage());
        }
    }
}
