#!/usr/bin/env bash
# montar.sh — monta um video vertical 1080x1920 (9:16) a partir de:
#   <dir>/narration.mp3        (obrigatorio)
#   <dir>/img_000.jpg, ...     (obrigatorio, 1+ imagens)
#   <dir>/subs.srt             (opcional — legendas queimadas)
# Saida: <dir>/final.mp4
#
# Sem dependencia de "bc" (usa awk). Fonte das legendas configuravel por env.
set -euo pipefail

DIR="${1:?uso: montar.sh <dir>}"
AUDIO="$DIR/narration.mp3"
SRT="$DIR/subs.srt"
OUT="$DIR/final.mp4"

# Fonte das legendas. Por padrao usa DejaVu (vem na imagem). Para usar Anton,
# coloque Anton.ttf em FONTS_DIR e defina FONT_NAME=Anton.
FONTS_DIR="${FONTS_DIR:-/usr/share/fonts}"
FONT_NAME="${FONT_NAME:-DejaVu Sans}"

W=1080; H=1920; FPS=25

[ -f "$AUDIO" ] || { echo "ERRO: $AUDIO nao encontrado" >&2; exit 1; }

# --- duracao do audio ---
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO" || true)
[ -n "${DUR:-}" ] || { echo "ERRO: ffprobe nao retornou duracao" >&2; exit 1; }

# --- imagens (ordenadas) ---
shopt -s nullglob
mapfile -t IMAGES < <(ls -1 "$DIR"/img_*.jpg "$DIR"/img_*.jpeg "$DIR"/img_*.png 2>/dev/null | sort)
N=${#IMAGES[@]}
[ "$N" -gt 0 ] || { echo "ERRO: nenhuma imagem img_* em $DIR" >&2; exit 1; }

# --- tempo por imagem e frames (awk no lugar de bc) ---
PERIMG=$(awk -v d="$DUR" -v n="$N" 'BEGIN{printf "%.3f", d/n}')
FRAMES=$(awk -v p="$PERIMG" -v f="$FPS" 'BEGIN{printf "%d", (p*f)+0.5}')
[ "$FRAMES" -lt 1 ] && FRAMES=1

echo "DUR=$DUR  N=$N  PERIMG=$PERIMG  FRAMES=$FRAMES"

# --- 1) um clipe por imagem, com zoom suave (Ken Burns) ---
: > "$DIR/list.txt"
i=0
for IMG in "${IMAGES[@]}"; do
  CLIP="$DIR/clip_$(printf '%03d' "$i").mp4"
  ffmpeg -y -loop 1 -i "$IMG" -t "$PERIMG" \
    -vf "scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},zoompan=z='min(zoom+0.0012,1.15)':d=${FRAMES}:s=${W}x${H}:fps=${FPS},setsar=1,format=yuv420p" \
    -r ${FPS} -c:v libx264 -preset veryfast -pix_fmt yuv420p -an "$CLIP"
  echo "file '$CLIP'" >> "$DIR/list.txt"
  i=$((i+1))
done

# --- 2) concatena os clipes (re-encode p/ garantir compatibilidade) ---
ffmpeg -y -f concat -safe 0 -i "$DIR/list.txt" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -r ${FPS} "$DIR/mudo.mp4"

# --- 3) audio + (opcional) legendas queimadas ---
if [ -f "$SRT" ]; then
  STYLE="FontName=${FONT_NAME},Fontsize=15,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,BorderStyle=3,Outline=2,Alignment=2,MarginV=140"
  ffmpeg -y -i "$DIR/mudo.mp4" -i "$AUDIO" \
    -vf "subtitles=${SRT}:fontsdir=${FONTS_DIR}:force_style='${STYLE}'" \
    -map 0:v -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -c:a aac -b:a 192k -shortest "$OUT"
else
  echo "AVISO: $SRT nao encontrado — gerando sem legendas." >&2
  ffmpeg -y -i "$DIR/mudo.mp4" -i "$AUDIO" \
    -map 0:v -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -c:a aac -b:a 192k -shortest "$OUT"
fi

echo "OK: $OUT"
