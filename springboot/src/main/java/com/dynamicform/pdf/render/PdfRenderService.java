package com.dynamicform.pdf.render;

import com.dynamicform.pdf.exception.FinalizeException;
import com.dynamicform.pdf.model.ErrorCode;
import com.openhtmltopdf.extend.FSSupplier;
import com.openhtmltopdf.outputdevice.helper.BaseRendererBuilder.FontStyle;
import com.openhtmltopdf.pdfboxout.PdfRendererBuilder;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.Resource;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;
import org.springframework.stereotype.Service;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * Stage 2.4 — converts a strict-XHTML string into PDF bytes via OpenHTMLtoPDF
 * (PDFBox backend), with fonts embedded explicitly.
 *
 * <p><b>Fonts matter.</b> OpenHTMLtoPDF ships no default fonts; if none are
 * registered, text silently disappears. All {@code *.ttf} files discovered under
 * {@code finalizer.fonts-dir} are embedded. The primary font is also aliased to
 * the family {@code "DejaVu Sans"} used by the renderer's stylesheet so body text
 * always resolves to a real glyph set (including the ☑ / ☐ checkbox glyphs).
 */
@Service
public class PdfRenderService {

    private static final Logger log = LoggerFactory.getLogger(PdfRenderService.class);
    private static final String DEFAULT_FAMILY = "DejaVu Sans";

    private final String fontsDir;
    private final List<FontResource> fonts = new ArrayList<>();

    public PdfRenderService(@Value("${finalizer.fonts-dir:classpath:fonts}") String fontsDir) {
        this.fontsDir = fontsDir;
        loadFonts();
    }

    /** Result of a render: the PDF bytes and the page count. */
    public record RenderResult(byte[] pdf, int pageCount) {}

    public RenderResult renderToPdf(String xhtml) {
        try (ByteArrayOutputStream out = new ByteArrayOutputStream(8192)) {
            PdfRendererBuilder builder = new PdfRendererBuilder();
            builder.useFastMode();
            registerFonts(builder);
            builder.withHtmlContent(xhtml, null);
            builder.toStream(out);
            builder.run();

            byte[] pdf = out.toByteArray();
            return new RenderResult(pdf, countPages(pdf));
        } catch (FinalizeException fe) {
            throw fe;
        } catch (Exception e) {
            // Most commonly: malformed XHTML or an unsupported CSS construct.
            throw new FinalizeException(ErrorCode.PDF_GEN_FAILED, "PDF rendering failed: " + e.getMessage(), e);
        }
    }

    private int countPages(byte[] pdf) {
        try (PDDocument doc = PDDocument.load(pdf)) {
            return doc.getNumberOfPages();
        } catch (Exception e) {
            log.warn("Could not read page count from generated PDF: {}", e.getMessage());
            return 0;
        }
    }

    // ------------------------------------------------------------------
    // Font discovery + registration
    // ------------------------------------------------------------------
    private void registerFonts(PdfRendererBuilder builder) {
        if (fonts.isEmpty()) {
            log.warn("No fonts registered (looked in '{}'). Text may not render. "
                    + "Drop a DejaVuSans.ttf into src/main/resources/fonts/.", fontsDir);
            return;
        }
        boolean defaultFamilyRegistered = false;
        for (FontResource fr : fonts) {
            builder.useFont(fr.supplier(), fr.family(), fr.weight(), fr.style(), true);
            if (DEFAULT_FAMILY.equalsIgnoreCase(fr.family())) {
                defaultFamilyRegistered = true;
            }
        }
        // Guarantee the stylesheet's default family resolves to a real font.
        if (!defaultFamilyRegistered) {
            FontResource primary = pickPrimary();
            builder.useFont(primary.supplier(), DEFAULT_FAMILY, 400, FontStyle.NORMAL, true);
            log.info("Aliased font '{}' to family '{}' for the default stylesheet.", primary.family(), DEFAULT_FAMILY);
        }
    }

    private FontResource pickPrimary() {
        for (FontResource fr : fonts) {
            String f = fr.family().toLowerCase();
            if (fr.weight() == 400 && fr.style() == FontStyle.NORMAL
                    && (f.contains("dejavu") || f.contains("sans") || f.contains("noto"))) {
                return fr;
            }
        }
        return fonts.get(0);
    }

    private void loadFonts() {
        try {
            String location = fontsDir.endsWith("/") ? fontsDir : fontsDir + "/";
            String pattern = location.startsWith("classpath")
                    ? location.replace("classpath:", "classpath*:") + "*.ttf"
                    : "file:" + location + "*.ttf";
            Resource[] resources = new PathMatchingResourcePatternResolver().getResources(pattern);
            for (Resource res : resources) {
                String name = res.getFilename();
                if (name == null) continue;
                fonts.add(toFontResource(res, name));
                log.info("Registered font resource: {}", name);
            }
        } catch (Exception e) {
            log.warn("Font discovery failed for '{}': {}", fontsDir, e.getMessage());
        }
    }

    private FontResource toFontResource(Resource res, String fileName) {
        String base = fileName.replaceFirst("(?i)\\.ttf$", "");
        String lower = base.toLowerCase();
        int weight = lower.contains("bold") ? 700 : 400;
        FontStyle style = (lower.contains("italic") || lower.contains("oblique")) ? FontStyle.ITALIC : FontStyle.NORMAL;
        // Family name: strip common weight/style suffixes so e.g. DejaVuSans-Bold -> "DejaVuSans".
        String family = base.replaceAll("(?i)[-_ ]?(bold|italic|oblique|regular)", "");
        if (family.isBlank()) family = base;
        // Read bytes once so the supplier can be re-invoked safely by the engine.
        byte[] data = readAll(res);
        FSSupplier<InputStream> supplier = () -> new ByteArrayInputStream(data);
        return new FontResource(family, weight, style, supplier);
    }

    private byte[] readAll(Resource res) {
        try (InputStream in = res.getInputStream()) {
            return in.readAllBytes();
        } catch (Exception e) {
            throw new FinalizeException(ErrorCode.INTERNAL, "Could not read font " + res.getFilename(), e);
        }
    }

    private record FontResource(String family, int weight, FontStyle style, FSSupplier<InputStream> supplier) {}
}
