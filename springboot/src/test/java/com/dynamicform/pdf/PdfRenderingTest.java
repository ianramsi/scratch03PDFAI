package com.dynamicform.pdf;

import com.dynamicform.pdf.model.FinalizeRequest;
import com.dynamicform.pdf.model.Schema;
import com.dynamicform.pdf.render.HtmlRenderer;
import com.dynamicform.pdf.render.PdfRenderService;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Verifications for stages 2.2 (DTO deserialization), 2.3 (HTML render) and
 * 2.4 (PDF render). Renders a comprehensive sample (the "Diesel Generator
 * Inspection Checklist") exercising every field type, including a multi-row
 * table and both signatures, and writes the PDF to target/test-output for
 * manual inspection.
 */
class PdfRenderingTest {

    private final ObjectMapper mapper = new ObjectMapper();

    // 1x1 transparent PNG, stands in for a real signature pulled from Salesforce.
    private static final String PNG_1PX =
            "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

    private static final String SAMPLE_REQUEST = """
            {
              "submissionId": "a0YAB000000XyZ12",
              "schema": {
                "title": "Diesel Generator Inspection Checklist",
                "orientation": "portrait",
                "paperSize": "A4",
                "sections": [
                  {
                    "id": "sec_header",
                    "title": "Unit Information",
                    "rows": [
                      {
                        "id": "r1",
                        "fields": [
                          { "id": "unit_id", "type": "text", "label": "Unit ID", "colSpan": 6 },
                          { "id": "inspect_date", "type": "date", "label": "Inspection Date", "colSpan": 6 }
                        ]
                      },
                      {
                        "id": "r2",
                        "fields": [
                          { "id": "site", "type": "text", "label": "Site", "colSpan": 8 },
                          { "id": "shift", "type": "picklist", "label": "Shift", "colSpan": 4, "options": ["Day","Night"] }
                        ]
                      }
                    ]
                  },
                  {
                    "id": "sec_checks",
                    "title": "Checks",
                    "rows": [
                      {
                        "id": "r3",
                        "fields": [
                          { "id": "oil_ok", "type": "checkbox", "label": "Oil level OK", "colSpan": 4 },
                          { "id": "coolant_ok", "type": "checkbox", "label": "Coolant OK", "colSpan": 4 },
                          { "id": "belts_ok", "type": "checkbox", "label": "Belts OK", "colSpan": 4 }
                        ]
                      },
                      {
                        "id": "r4",
                        "fields": [
                          {
                            "id": "readings",
                            "type": "table",
                            "label": "Hourly Readings",
                            "columns": [
                              { "id": "hour", "label": "Hour", "type": "text" },
                              { "id": "voltage", "label": "Voltage (V)", "type": "number" },
                              { "id": "temp", "label": "Temp (C)", "type": "number" },
                              { "id": "alarm", "label": "Alarm", "type": "checkbox" }
                            ]
                          }
                        ]
                      },
                      {
                        "id": "r5",
                        "fields": [
                          { "id": "notes", "type": "textarea", "label": "Notes", "colSpan": 12 }
                        ]
                      }
                    ]
                  },
                  {
                    "id": "sec_sign",
                    "title": "Sign-off",
                    "rows": [
                      {
                        "id": "r6",
                        "fields": [
                          { "id": "sig_eng", "type": "signature", "label": "Engineer", "colSpan": 6, "signerRole": "engineer" },
                          { "id": "sig_sup", "type": "signature", "label": "Supervisor", "colSpan": 6, "signerRole": "supervisor" }
                        ]
                      }
                    ]
                  }
                ]
              },
              "data": {
                "values": {
                  "unit_id": "GEN-2026-014",
                  "inspect_date": "2026-06-30",
                  "site": "North Plant - Bay 3",
                  "shift": "Night",
                  "oil_ok": true,
                  "coolant_ok": true,
                  "belts_ok": false,
                  "notes": "Belt tension low on alternator.\\nFlagged for replacement next service window.",
                  "readings": [
                    { "hour": "08:00", "voltage": 415, "temp": 72, "alarm": false },
                    { "hour": "09:00", "voltage": 416, "temp": 74, "alarm": false },
                    { "hour": "10:00", "voltage": 410, "temp": 81, "alarm": true }
                  ]
                }
              },
              "signatures": {
                "engineer":   { "contentVersionId": "068000000000001", "signedBy": "John Doe",  "signedAt": "2026-06-30T08:15:00Z" },
                "supervisor": { "contentVersionId": "068000000000002", "signedBy": "Jane Smith", "signedAt": "2026-06-30T11:42:00Z" }
              },
              "salesforceFileApi": { "instanceUrl": "https://example.my.salesforce.com", "accessToken": "00Dxx-token" }
            }
            """;

    @Test
    void deserializesSampleRequest() throws Exception {
        FinalizeRequest req = mapper.readValue(SAMPLE_REQUEST, FinalizeRequest.class);

        assertEquals("a0YAB000000XyZ12", req.submissionId());
        assertNotNull(req.schema());
        assertEquals("Diesel Generator Inspection Checklist", req.schema().title());
        assertEquals(3, req.schema().sections().size());
        assertEquals("068000000000001", req.signatures().engineer().contentVersionId());
        assertEquals("00Dxx-token", req.salesforceFileApi().accessToken());

        // Table value deserializes as a List of Maps (tableId -> rows).
        Object readings = req.data().safeValues().get("readings");
        assertTrue(readings instanceof List<?>);
        assertEquals(3, ((List<?>) readings).size());
    }

    @Test
    void rendersSampleToPdf() throws Exception {
        FinalizeRequest req = mapper.readValue(SAMPLE_REQUEST, FinalizeRequest.class);
        Schema schema = req.schema();
        Map<String, Object> values = req.data().safeValues();

        Map<String, String> sigUri = Map.of("engineer", PNG_1PX, "supervisor", PNG_1PX);
        Map<String, String[]> sigMeta = Map.of(
                "engineer", new String[]{"John Doe", "2026-06-30T08:15:00Z"},
                "supervisor", new String[]{"Jane Smith", "2026-06-30T11:42:00Z"});

        HtmlRenderer htmlRenderer = new HtmlRenderer();
        String html = htmlRenderer.render(schema, values, sigUri, sigMeta);

        // Sanity on the rendered XHTML before touching the PDF engine.
        assertTrue(html.startsWith("<?xml"), "must be well-formed XHTML");
        assertTrue(html.contains("Diesel Generator Inspection Checklist"));
        assertTrue(html.contains("data-table"), "table field should render a data-table");
        assertTrue(html.contains("\u2611") || html.contains("\u2610"), "checkbox glyphs present");

        PdfRenderService pdf = new PdfRenderService("classpath:fonts");
        PdfRenderService.RenderResult result = pdf.renderToPdf(html);

        assertTrue(result.pdf().length > 1000, "PDF should be non-trivial");
        assertEquals('%', (char) result.pdf()[0]);
        assertEquals('P', (char) result.pdf()[1]);
        assertEquals('D', (char) result.pdf()[2]);
        assertEquals('F', (char) result.pdf()[3]);
        assertTrue(result.pageCount() >= 1, "should have at least one page");

        Path out = Path.of("target", "test-output");
        Files.createDirectories(out);
        Path file = out.resolve("sample.pdf");
        Files.write(file, result.pdf());
        System.out.println("Wrote sample PDF (" + result.pageCount() + " pages) to "
                + file.toAbsolutePath());
    }
}
