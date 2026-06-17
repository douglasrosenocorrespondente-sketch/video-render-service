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

# Resolucao padrao 720x1280 (9:16): ~2x mais rapido que 1080x1920 em VPS fraco.
# Suba p/ 1080x1920 (VID_W/VID_H) so com VPS de 2+ vCPU.
W="${VID_W:-720}"; H="${VID_H:-1280}"; FPS=25
# 1 thread: o container ja esta limitado a 0.5 CPU no easypanel
FF_THREADS="${FF_THREADS:-1}"

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
        # imagem estatica com FUNDO BORRADO: a foto inteira aparece centralizada
        # (sem cortar ninguem) e as bordas sao preenchidas com a propria foto borrada.
        # Blur barato (downscale->upscale) p/ nao pesar no VPS.
        ffmpeg -y -threads ${FF_THREADS} -loop 1 -i "$M" -t "$PERIMG" \
          -vf "split[a][b];[b]scale=120:213,scale=${W}:${H},setsar=1[bg];[a]scale=${W}:${H}:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1,fps=${FPS},format=yuv420p" \
          -r ${FPS} -c:v libx264 -preset ultrafast -pix_fmt yuv420p -an "$CLIP"
      fi
      ;;
  esac
  echo "file '$CLIP'" >> "$DIR/list.txt"
  i=$((i+1))
done

# --- 2) concatena os clipes (copia direta: clipes ja tem mesmo codec/params) ---
ffmpeg -y -f concat -safe 0 -i "$DIR/list.txt" -c copy "$DIR/mudo.mp4"

# --- 3) audio (narracao + musica de fundo opcional) + legendas queimadas ---
# MarginV/Fontsize no espaco ASS padrao (288px), escalados p/ a altura do video.
STYLE="FontName=${FONT_NAME},Fontsize=18,Bold=1,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,BorderStyle=1,Outline=2,Shadow=1,Alignment=2,MarginV=70"
if [ -f "$SRT" ]; then
  VFILTER="subtitles=${SRT}:fontsdir=${FONTS_DIR}:force_style='${STYLE}'"
else
  echo "AVISO: $SRT nao encontrado — gerando sem legendas." >&2
  VFILTER="null"
fi

# trilha de fundo: 1o arquivo em MUSIC_DIR (se houver). Coloque mp3 sem copyright la.
MUSIC_DIR="${MUSIC_DIR:-/app/music}"
MUSIC_VOLUME="${MUSIC_VOLUME:-0.12}"
MUSICS=("$MUSIC_DIR"/*.mp3 "$MUSIC_DIR"/*.m4a "$MUSIC_DIR"/*.wav)

if [ ${#MUSICS[@]} -gt 0 ]; then
  MUSIC="${MUSICS[RANDOM % ${#MUSICS[@]}]}"
  echo "Musica de fundo: $MUSIC (vol=$MUSIC_VOLUME)"
  # narracao em volume cheio + musica em loop e volume baixo (normalize=0 nao abaixa a narracao)
  ffmpeg -y -threads ${FF_THREADS} -i "$DIR/mudo.mp4" -i "$AUDIO" -stream_loop -1 -i "$MUSIC" \
    -filter_complex "[0:v]${VFILTER}[v];[2:a]volume=${MUSIC_VOLUME}[bg];[1:a][bg]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]" \
    -map "[v]" -map "[a]" -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    -c:a aac -b:a 192k -shortest "$OUT"
else
  echo "Sem musica de fundo (nenhum arquivo em $MUSIC_DIR)."
  ffmpeg -y -threads ${FF_THREADS} -i "$DIR/mudo.mp4" -i "$AUDIO" \
    -filter_complex "[0:v]${VFILTER}[v]" \
    -map "[v]" -map 1:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    -c:a aac -b:a 192k -shortest "$OUT"
fi

echo "OK: $OUT"
