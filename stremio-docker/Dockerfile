FROM stremio/server:latest

# Instala ffmpeg moderno + VAAPI drivers
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        mesa-va-drivers \
        vainfo && \
    rm -rf /var/lib/apt/lists/*
