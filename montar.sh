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
FONT_NAME="${FONT_NAME:-Anton}"

W=1080; H=1920; FPS=25
# limita threads do ffmpeg p/ nao tomar toda a CPU do VPS (e derrubar o n8n)
FF_THREADS="${FF_THREADS:-2}"

[ -f "$AUDIO" ] || { echo "ERRO: $AUDIO nao encontrado" >&2; exit 1; }

# --- duracao do audio ---
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO" || true)
[ -n "${DUR:-}" ] || { echo "ERRO: ffprobe nao retornou duracao" >&2; exit 1; }

# --- midia (b-roll de video e/ou imagens), ordenada ---
shopt -s nullglob
mapfile -t MEDIA < <(ls -1 "$DIR"/media_* 2>/dev/null | sort)
if [ ${#MEDIA[@]} -eq 0 ]; then
  mapfile -t MEDIA < <(ls -1 "$DIR"/img_*.jpg "$DIR"/img_*.jpeg "$DIR"/img_*.png 2>/dev/null | sort)
fi
N=${#MEDIA[@]}
[ "$N" -gt 0 ] || { echo "ERRO: nenhuma midia (media_*/img_*) em $DIR" >&2; exit 1; }

# --- tempo por imagem e frames (awk no lugar de bc) ---
PERIMG=$(awk -v d="$DUR" -v n="$N" 'BEGIN{printf "%.3f", d/n}')
FRAMES=$(awk -v p="$PERIMG" -v f="$FPS" 'BEGIN{printf "%d", (p*f)+0.5}')
[ "$FRAMES" -lt 1 ] && FRAMES=1

echo "DUR=$DUR  N=$N  PERIMG=$PERIMG  FRAMES=$FRAMES"

# --- 1) um clipe por midia: video recortado em 9:16 OU imagem com Ken Burns ---
: > "$DIR/list.txt"
i=0
for M in "${MEDIA[@]}"; do
  CLIP="$DIR/clip_$(printf '%03d' "$i").mp4"
  case "${M,,}" in
    *.mp4|*.mov|*.webm|*.mkv|*.m4v)
      # b-roll: loopa p/ preencher PERIMG, recorta 9:16, sem audio
      ffmpeg -y -threads ${FF_THREADS} -stream_loop -1 -i "$M" -t "$PERIMG" -an \
        -vf "scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},setsar=1,fps=${FPS},format=yuv420p" \
        -r ${FPS} -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$CLIP"
      ;;
    *)
      if [ "${KENBURNS:-0}" = "1" ]; then
        # imagem com zoom suave (Ken Burns) — pesado de CPU, so com VPS folgado
        ffmpeg -y -threads ${FF_THREADS} -loop 1 -i "$M" -t "$PERIMG" \
          -vf "scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},zoompan=z='min(zoom+0.0012,1.15)':d=${FRAMES}:s=${W}x${H}:fps=${FPS},setsar=1,format=yuv420p" \
          -r ${FPS} -c:v libx264 -preset ultrafast -pix_fmt yuv420p -an "$CLIP"
      else
        # imagem estatica (leve): so escala/recorta, sem zoom
        ffmpeg -y -threads ${FF_THREADS} -loop 1 -i "$M" -t "$PERIMG" \
          -vf "scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},setsar=1,fps=${FPS},format=yuv420p" \
          -r ${FPS} -c:v libx264 -preset ultrafast -pix_fmt yuv420p -an "$CLIP"
      fi
      ;;
  esac
  echo "file '$CLIP'" >> "$DIR/list.txt"
  i=$((i+1))
done

# --- 2) concatena os clipes (copia direta: clipes ja tem mesmo codec/params) ---
ffmpeg -y -f concat -safe 0 -i "$DIR/list.txt" -c copy "$DIR/mudo.mp4"

# --- 3) audio + (opcional) legendas queimadas ---
if [ -f "$SRT" ]; then
  # Fontsize/MarginV/Outline sao interpretados no espaco ASS padrao (288px de altura)
  # e escalados ~6.6x p/ 1920. MarginV=70 -> ~terco inferior; Fontsize=18 -> ~120px.
  STYLE="FontName=${FONT_NAME},Fontsize=18,Bold=1,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,BorderStyle=1,Outline=2,Shadow=1,Alignment=2,MarginV=70"
  ffmpeg -y -threads ${FF_THREADS} -i "$DIR/mudo.mp4" -i "$AUDIO" \
    -vf "subtitles=${SRT}:fontsdir=${FONTS_DIR}:force_style='${STYLE}'" \
    -map 0:v -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -c:a aac -b:a 192k -shortest "$OUT"
else
  echo "AVISO: $SRT nao encontrado — gerando sem legendas." >&2
  ffmpeg -y -threads ${FF_THREADS} -i "$DIR/mudo.mp4" -i "$AUDIO" \
    -map 0:v -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -c:a aac -b:a 192k -shortest "$OUT"
fi

echo "OK: $OUT"
