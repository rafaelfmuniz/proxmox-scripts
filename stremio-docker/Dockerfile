FROM stremio/server:latest

RUN apt-get update && \
    apt-get install -y ffmpeg mesa-va-drivers vainfo && \
    rm -rf /var/lib/apt/lists/*
