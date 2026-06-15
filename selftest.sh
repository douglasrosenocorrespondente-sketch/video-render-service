#!/usr/bin/env bash
# selftest.sh — gera assets sinteticos e roda montar.sh + thumb.sh.
# Prova, isolado, que o pipeline ffmpeg produz um final.mp4 correto.
# uso: selftest.sh [dir]   (default: diretorio temporario)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${1:-$(mktemp -d)}"
mkdir -p "$DIR"

echo ">> Gerando assets de teste em $DIR"

# 3 imagens coloridas 1080x1920 com um numero no meio
i=0
for COLOR in "0x1e3a8a" "0x065f46" "0x7c2d12"; do
  ffmpeg -y -f lavfi -i "color=c=${COLOR}:s=1080x1920:d=1" \
    -vf "drawtext=text='TESTE $((i+1))':fontcolor=white:fontsize=160:x=(w-text_w)/2:y=(h-text_h)/2:fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" \
    -frames:v 1 "$DIR/img_$(printf '%03d' $i).jpg"
  i=$((i+1))
done

# audio de teste: 6s de tom 220Hz
ffmpeg -y -f lavfi -i "sine=frequency=220:duration=6" -ac 2 -b:a 192k "$DIR/narration.mp3"

# legenda de teste
cat > "$DIR/subs.srt" <<'SRT'
1
00:00:00,000 --> 00:00:03,000
Legenda de teste — linha um

2
00:00:03,000 --> 00:00:06,000
Legenda de teste — linha dois
SRT

echo ">> Rodando montar.sh"
bash "$HERE/montar.sh" "$DIR"

echo ">> Rodando thumb.sh"
bash "$HERE/thumb.sh" "$DIR" "TESTE OK"

echo ">> Conteudo final:"
ls -lh "$DIR"/final.mp4 "$DIR"/thumb.jpg
ffprobe -v error -show_entries format=duration,format=size -of default=nw=1 "$DIR/final.mp4"
echo ">> SELFTEST OK"
