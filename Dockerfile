# Block Party referee server for Render (free tier).
# Runs the same Godot project as the app, headless, in --server mode.
FROM debian:bookworm-slim

ARG GODOT_VERSION=4.7.2
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip libfontconfig1 \
 && curl -fsSL -o /tmp/godot.zip "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" \
 && unzip /tmp/godot.zip -d /opt \
 && mv /opt/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
 && chmod +x /usr/local/bin/godot \
 && rm /tmp/godot.zip \
 && apt-get purge -y curl unzip && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY game/ /app/
# Import resources once at build time so startup is fast.
RUN godot --headless --path /app --import || true

ENV PORT=10000
EXPOSE 10000
CMD ["sh", "-c", "exec godot --headless --path /app -- --server"]
