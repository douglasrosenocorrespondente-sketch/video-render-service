#!/usr/bin/env bash
# thumb.sh — gera uma thumbnail 1280x720 com texto sobre a 1a imagem.
#   <dir>/img_000.jpg  -> <dir>/thumb.jpg
# uso: thumb.sh <dir> "TEXTO DA THUMB"
set -euo pipefail

DIR="${1:?uso: thumb.sh <dir> <texto>}"
TEXT="${2:-}"

# Arquivo .ttf real para o drawtext (precisa do caminho do arquivo, nao do nome da familia)
FONT_FILE="${FONT_FILE:-/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf}"

shopt -s nullglob
SRC=$(ls -1 "$DIR"/img_*.jpg "$DIR"/img_*.jpeg "$DIR"/img_*.png 2>/dev/null | sort | head -1)
[ -n "${SRC:-}" ] || { echo "ERRO: sem imagem em $DIR" >&2; exit 1; }

# escapa caracteres especiais do drawtext
ESC=$(printf '%s' "$TEXT" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/'/\\\\\\\\'/g" -e "s/:/\\\\:/g" -e "s/%/\\\\%/g")

ffmpeg -y -i "$SRC" \
  -vf "scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,drawtext=fontfile='${FONT_FILE}':text='${ESC}':fontcolor=white:fontsize=90:box=1:boxcolor=red@0.85:boxborderw=18:x=(w-text_w)/2:y=h-230" \
  -frames:v 1 "$DIR/thumb.jpg"

echo "OK: $DIR/thumb.jpg"
