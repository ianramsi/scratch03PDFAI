package com.dynamicform.pdf.model;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.util.List;

/**
 * Form schema (mirrors the Apex {@code FormSchemaValidator} contract).
 *
 * <p>Structure: {@code sections -> rows -> fields}, laid out on a 12-column grid
 * via {@code field.colSpan}. {@code orientation}/{@code paperSize} drive page setup.
 * Unknown properties are ignored so the renderer tolerates schema evolution.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record Schema(
        String title,
        String orientation,   // "portrait" | "landscape" (optional, default portrait)
        String paperSize,     // e.g. "A4" (optional, default A4)
        List<Section> sections
) {

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Section(String id, String title, List<Row> rows) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Row(String id, List<Field> fields) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Field(
            String id,
            String type,
            String label,
            Integer colSpan,
            Boolean required,
            List<String> options,     // picklist
            String signerRole,        // signature: "engineer" | "supervisor"
            List<Column> columns,     // table
            Integer maxRows           // table
    ) {
        /** colSpan defaults to full width (12) when absent, matching the validator. */
        public int effectiveColSpan() {
            return (colSpan == null || colSpan < 1) ? 12 : Math.min(colSpan, 12);
        }
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Column(String id, String label, String type, List<String> options) {}
}
