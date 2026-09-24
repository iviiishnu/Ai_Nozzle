package com.example.spring_backend.model;


public class CropAnalysisResult {
    private String crop;
    private String health;
    private String nutrition;

    // Getters and Setters
    public String getCrop() { return crop; }
    public void setCrop(String crop) { this.crop = crop; }

    public String getHealth() { return health; }
    public void setHealth(String health) { this.health = health; }

    public String getNutrition() { return nutrition; }
    public void setNutrition(String nutrition) { this.nutrition = nutrition; }
}
