package com.dynamicform.pdf.render;

import com.dynamicform.pdf.model.Schema;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Stage 2.3 — renders {@code schema + data.values} into a single strict-XHTML
 * string for OpenHTMLtoPDF.
 *
 * <p><b>Why XHTML + tables.</b> OpenHTMLtoPDF (Flying Saucer core) consumes
 * strict XHTML and CSS 2.1 only — no HTML5 parsing, no flexbox/grid. Every tag
 * must be closed and every attribute quoted. The 12-column grid is therefore
 * built with real {@code <table>}s (table-layout: fixed) rather than
 * flexbox/inline-block, which is the most deterministic layout primitive the
 * engine supports. Data tables repeat their header row across page breaks and
 * avoid splitting a row mid-cell.
 *
 * <p>This class performs NO I/O. Signature images are passed in as pre-resolved
 * data-URIs (built in stage 2.5 before rendering).
 */
@Component
public class HtmlRenderer {

    private static final int GRID = 12;
    private static final String CHECKED = "\u2611";    // ☑
    private static final String UNCHECKED = "\u2610";  // ☐

    /**
     * @param schema                 validated form schema
     * @param values                 data.values map (fieldId -> scalar | tableId -> rows)
     * @param signatureDataUriByRole signerRole -> {@code data:image/...;base64,...}
     * @param signatureMeta          signerRole -> [signedBy, signedAt] for the caption
     * @return a complete, well-formed XHTML document
     */
    public String render(Schema schema,
                         Map<String, Object> values,
                         Map<String, String> signatureDataUriByRole,
                         Map<String, String[]> signatureMeta) {
        Map<String, Object> v = values == null ? Map.of() : values;
        StringBuilder sb = new StringBuilder(4096);

        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        sb.append("<html xmlns=\"http://www.w3.org/1999/xhtml\">\n<head>\n");
        sb.append("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\" />\n");
        sb.append("<style type=\"text/css\">\n").append(css(schema)).append("\n</style>\n");
        sb.append("</head>\n<body>\n");

        if (has(schema.title())) {
            sb.append("<h1 class=\"form-title\">").append(esc(schema.title())).append("</h1>\n");
        }

        for (Schema.Section section : nullSafe(schema.sections())) {
            if (section == null) continue;
            sb.append("<div class=\"section\">\n");
            if (has(section.title())) {
                sb.append("<h2 class=\"section-title\">").append(esc(section.title())).append("</h2>\n");
            }
            for (Schema.Row row : nullSafe(section.rows())) {
                renderRow(sb, row, v, signatureDataUriByRole, signatureMeta);
            }
            sb.append("</div>\n");
        }

        sb.append("</body>\n</html>\n");
        return sb.toString();
    }

    // ------------------------------------------------------------------
    // Row -> grid table
    // ------------------------------------------------------------------
    private void renderRow(StringBuilder sb, Schema.Row row, Map<String, Object> values,
                           Map<String, String> sigUri, Map<String, String[]> sigMeta) {
        if (row == null) return;
        List<Schema.Field> fields = nullSafe(row.fields());
        if (fields.isEmpty()) return;

        int span = 0;
        for (Schema.Field f : fields) {
            if (f != null) span += f.effectiveColSpan();
        }

        sb.append("<table class=\"grid-row\"><tbody><tr>\n");
        for (Schema.Field field : fields) {
            if (field == null) continue;
            int cs = field.effectiveColSpan();
            sb.append("<td class=\"grid-cell\" style=\"width:").append(pct(cs)).append("\">");
            renderField(sb, field, values, sigUri, sigMeta);
            sb.append("</td>\n");
        }
        // Pad the remaining grid width so cells keep their intended proportions.
        if (span < GRID) {
            sb.append("<td class=\"grid-spacer\" style=\"width:").append(pct(GRID - span)).append("\"></td>\n");
        }
        sb.append("</tr></tbody></table>\n");
    }

    // ------------------------------------------------------------------
    // Field dispatch
    // ------------------------------------------------------------------
    private void renderField(StringBuilder sb, Schema.Field field, Map<String, Object> values,
                             Map<String, String> sigUri, Map<String, String[]> sigMeta) {
        String type = field.type() == null ? "text" : field.type();
        Object raw = values.get(field.id());

        switch (type) {
            case "checkbox" -> renderCheckbox(sb, field, raw);
            case "table" -> renderTable(sb, field, raw);
            case "signature" -> renderSignature(sb, field, sigUri, sigMeta);
            case "textarea" -> renderTextarea(sb, field, raw);
            // text, number, date, time, picklist all render as label + scalar value.
            default -> renderScalar(sb, field, raw);
        }
    }

    private void renderScalar(StringBuilder sb, Schema.Field field, Object raw) {
        sb.append("<div class=\"field\">");
        label(sb, field);
        sb.append("<div class=\"value\">").append(esc(scalar(raw))).append("</div>");
        sb.append("</div>");
    }

    private void renderTextarea(StringBuilder sb, Schema.Field field, Object raw) {
        sb.append("<div class=\"field\">");
        label(sb, field);
        sb.append("<div class=\"value multiline\">").append(multiline(scalar(raw))).append("</div>");
        sb.append("</div>");
    }

    private void renderCheckbox(StringBuilder sb, Schema.Field field, Object raw) {
        boolean checked = asBool(raw);
        sb.append("<div class=\"field checkbox\">");
        sb.append("<span class=\"box\">").append(checked ? CHECKED : UNCHECKED).append("</span>");
        sb.append("<span class=\"check-label\">").append(esc(labelText(field))).append("</span>");
        sb.append("</div>");
    }

    private void renderSignature(StringBuilder sb, Schema.Field field,
                                 Map<String, String> sigUri, Map<String, String[]> sigMeta) {
        String role = field.signerRole();
        String uri = sigUri == null ? null : sigUri.get(role);
        sb.append("<div class=\"field signature\">");
        label(sb, field);
        if (has(uri)) {
            sb.append("<img class=\"sig-img\" src=\"").append(esc(uri)).append("\" alt=\"signature\" />");
        } else {
            sb.append("<div class=\"sig-missing\">(no signature)</div>");
        }
        String[] meta = sigMeta == null ? null : sigMeta.get(role);
        if (meta != null) {
            String signedBy = meta.length > 0 ? meta[0] : null;
            String signedAt = meta.length > 1 ? meta[1] : null;
            sb.append("<div class=\"sig-caption\">");
            if (has(signedBy)) sb.append(esc(signedBy));
            if (has(signedAt)) sb.append(has(signedBy) ? " &#183; " : "").append(esc(signedAt));
            sb.append("</div>");
        }
        sb.append("</div>");
    }

    @SuppressWarnings("unchecked")
    private void renderTable(StringBuilder sb, Schema.Field field, Object raw) {
        List<Schema.Column> columns = nullSafe(field.columns());
        sb.append("<div class=\"field table-field\">");
        label(sb, field);

        sb.append("<table class=\"data-table\"><thead><tr>");
        for (Schema.Column col : columns) {
            if (col == null) continue;
            sb.append("<th>").append(esc(col.label() != null ? col.label() : col.id())).append("</th>");
        }
        sb.append("</tr></thead><tbody>");

        List<Object> rows = (raw instanceof List<?>) ? (List<Object>) raw : List.of();
        if (rows.isEmpty()) {
            int colCount = Math.max(1, columns.size());
            sb.append("<tr><td class=\"empty\" colspan=\"").append(colCount).append("\">(no rows)</td></tr>");
        } else {
            for (Object rowObj : rows) {
                Map<String, Object> cells = (rowObj instanceof Map<?, ?>) ? (Map<String, Object>) rowObj : Map.of();
                sb.append("<tr>");
                for (Schema.Column col : columns) {
                    if (col == null) continue;
                    Object cell = cells.get(col.id());
                    sb.append("<td>");
                    if ("checkbox".equals(col.type())) {
                        sb.append(asBool(cell) ? CHECKED : UNCHECKED);
                    } else {
                        sb.append(esc(scalar(cell)));
                    }
                    sb.append("</td>");
                }
                sb.append("</tr>");
            }
        }
        sb.append("</tbody></table></div>");
    }

    // ------------------------------------------------------------------
    // Shared helpers
    // ------------------------------------------------------------------
    private void label(StringBuilder sb, Schema.Field field) {
        sb.append("<div class=\"label\">").append(esc(labelText(field))).append("</div>");
    }

    private String labelText(Schema.Field field) {
        return has(field.label()) ? field.label() : (field.id() == null ? "" : field.id());
    }

    /** colSpan -> width percentage string, US locale to force '.' decimals. */
    private String pct(int colSpan) {
        return String.format(Locale.US, "%.4f%%", (colSpan * 100.0) / GRID);
    }

    private String scalar(Object raw) {
        if (raw == null) return "";
        if (raw instanceof Boolean b) return b ? "Yes" : "No";
        return String.valueOf(raw);
    }

    private boolean asBool(Object raw) {
        if (raw instanceof Boolean b) return b;
        if (raw instanceof String s) return "true".equalsIgnoreCase(s.trim()) || "yes".equalsIgnoreCase(s.trim());
        return false;
    }

    /** Escape text then turn newlines into XHTML <br/> for multiline values. */
    private String multiline(String text) {
        return esc(text).replace("\n", "<br/>");
    }

    /** XML/XHTML escape for both text nodes and attribute values. */
    static String esc(String s) {
        if (s == null || s.isEmpty()) return "";
        StringBuilder out = new StringBuilder(s.length() + 16);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '&' -> out.append("&amp;");
                case '<' -> out.append("&lt;");
                case '>' -> out.append("&gt;");
                case '"' -> out.append("&quot;");
                case '\'' -> out.append("&#39;");
                default -> out.append(c);
            }
        }
        return out.toString();
    }

    private static boolean has(String s) {
        return s != null && !s.isEmpty();
    }

    private static <T> List<T> nullSafe(List<T> list) {
        return list == null ? List.of() : list;
    }

    // ------------------------------------------------------------------
    // CSS (strict CSS 2.1 only)
    // ------------------------------------------------------------------
    private String css(Schema schema) {
        String size = (has(schema.paperSize()) ? schema.paperSize() : "A4")
                + " "
                + ("landscape".equalsIgnoreCase(schema.orientation()) ? "landscape" : "portrait");
        return """
                @page { size: %s; margin: 2cm; }
                body { font-family: 'DejaVu Sans', sans-serif; font-size: 10pt; color: #1a1a1a; }
                h1.form-title { font-size: 16pt; margin: 0 0 12pt 0; text-align: center; }
                .section { margin-bottom: 10pt; }
                h2.section-title { font-size: 12pt; margin: 8pt 0 4pt 0; padding-bottom: 2pt; border-bottom: 1px solid #888; }
                table.grid-row { width: 100%%; table-layout: fixed; border-collapse: collapse; }
                td.grid-cell { vertical-align: top; padding: 2pt 4pt 2pt 0; }
                .field { margin-bottom: 4pt; }
                .label { font-size: 8pt; color: #555; margin-bottom: 1pt; }
                .value { min-height: 12pt; border-bottom: 1px solid #ccc; padding-bottom: 1pt; word-wrap: break-word; }
                .value.multiline { white-space: normal; }
                .field.checkbox .box { font-size: 12pt; vertical-align: middle; }
                .field.checkbox .check-label { vertical-align: middle; margin-left: 3pt; }
                .field.signature .sig-img { max-height: 60pt; max-width: 100%%; border-bottom: 1px solid #999; }
                .field.signature .sig-missing { color: #999; font-style: italic; }
                .field.signature .sig-caption { font-size: 8pt; color: #555; margin-top: 2pt; }
                table.data-table { width: 100%%; border-collapse: collapse; -fs-table-paginate: paginate; margin-top: 2pt; }
                table.data-table th, table.data-table td { border: 1px solid #999; padding: 2pt 4pt; font-size: 9pt; text-align: left; word-wrap: break-word; }
                table.data-table thead { display: table-header-group; }
                table.data-table tr { page-break-inside: avoid; }
                table.data-table td.empty { color: #999; font-style: italic; text-align: center; }
                """.formatted(size);
    }
}
