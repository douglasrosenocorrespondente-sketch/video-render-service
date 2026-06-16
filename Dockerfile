FROM python:3.12-slim

# ffmpeg + fontes (DejaVu) + fontconfig p/ legendas; curl p/ healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        fonts-dejavu-core \
        fontconfig \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py montar.sh thumb.sh selftest.sh ./
RUN chmod +x montar.sh thumb.sh selftest.sh

# Fonte Anton (condensada, estilo esportivo) baixada do Google Fonts no build
RUN curl -fsSL --create-dirs \
        -o /usr/share/fonts/truetype/anton/Anton-Regular.ttf \
        https://github.com/google/fonts/raw/main/ofl/anton/Anton-Regular.ttf \
    && fc-cache -f

ENV PORT=8088 \
    FONTS_DIR=/usr/share/fonts \
    FONT_NAME=Anton \
    FONT_FILE=/usr/share/fonts/truetype/anton/Anton-Regular.ttf

EXPOSE 8088

# 1 worker, timeout alto (render de ~90s pode levar 1-3 min)
CMD ["gunicorn", "-b", "0.0.0.0:8088", "-w", "1", "-t", "600", "app:app"]
