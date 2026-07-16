# ──────────────────────────────────────────────────────────────────────────────
# Stage 1: Build
# Uses the full Maven + JDK 17 image to compile and package the fat JAR.
# Nothing from this stage leaks into the runtime image.
# ──────────────────────────────────────────────────────────────────────────────
FROM --platform=linux/amd64 eclipse-temurin:17-jdk-jammy AS builder

WORKDIR /build

# Copy pom first — lets Docker cache the dependency layer separately from source.
COPY pom.xml .
RUN apt-get update && apt-get install -y maven && apt-get clean

# Download dependencies (cached unless pom.xml changes).
RUN mvn dependency:go-offline -q

# Copy source and build. Tests run separately in CI; skip here for a fast image build.
COPY src ./src
RUN mvn package -DskipTests -q

# ──────────────────────────────────────────────────────────────────────────────
# Stage 2: Runtime
# Slim JRE-only image. Only the JAR and fonts are copied in.
# Result: ~220 MB image vs ~600 MB if we kept the JDK + Maven.
# ──────────────────────────────────────────────────────────────────────────────
FROM --platform=linux/amd64 eclipse-temurin:17-jre-jammy

WORKDIR /app

# Non-root user — defense-in-depth; no reason the PDF service needs root.
RUN groupadd --gid 1001 appgroup \
 && useradd  --uid 1001 --gid 1001 --no-create-home appuser

# Copy the fat JAR produced by Stage 1.
COPY --from=builder /build/target/pdf-finalizer-*.jar app.jar

# Copy fonts directory so DejaVuSans.ttf is baked into the image.
# OpenHTMLtoPDF will NOT silently fall back — missing fonts = invisible text.
COPY src/main/resources/fonts ./fonts

# PDFBox writes a font cache to disk on first run. Give it a writable directory.
RUN mkdir -p /tmp/pdfbox-cache && chown appuser:appgroup /tmp/pdfbox-cache

USER appuser

EXPOSE 8080

# JVM flags:
#   -XX:+UseContainerSupport        honour cgroup memory limits (important in Docker)
#   -XX:MaxRAMPercentage=70.0       use up to 70% of container RAM for heap
#   -Djava.io.tmpdir=/tmp/pdfbox-cache  give PDFBox its writable scratch space
#   -Dfile.encoding=UTF-8           consistent encoding for XHTML/PDF text
ENTRYPOINT ["java", \
  "-XX:+UseContainerSupport", \
  "-XX:MaxRAMPercentage=70.0", \
  "-Djava.io.tmpdir=/tmp/pdfbox-cache", \
  "-Dfile.encoding=UTF-8", \
  "-jar", "app.jar"]
