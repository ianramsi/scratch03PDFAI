package com.dynamicform.pdf;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * PDF Finalization service — Phase 2 of the Dynamic Form MVP.
 *
 * <p>Single responsibility: when a form submission is approved in Salesforce,
 * render the schema + data into a deterministic PDF (the official record),
 * embed signature images, hash it, upload it back to Salesforce, and return the
 * ContentVersion id + hash. OpenHTMLtoPDF needs a JVM that exists in neither
 * Salesforce nor n8n — hence this service.
 */
@SpringBootApplication
public class PdfFinalizerApplication {
    public static void main(String[] args) {
        SpringApplication.run(PdfFinalizerApplication.class, args);
    }
}
