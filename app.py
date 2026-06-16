"""
Serviço de render de vídeo para o n8n (canal de notícias esportivas).

A instância n8n é read-only e sem `Execute Command`, então este serviço isolado
faz TODO o trabalho pesado e devolve o vídeo pronto via HTTP. O n8n faz uma única
chamada com o áudio e fica como orquestrador fino, em memória.

O serviço, ao receber o áudio:
  1. (opcional) busca imagens no Pexels a partir de termos de busca;
  2. (opcional) transcreve o áudio no OpenAI Whisper para gerar as legendas .srt;
  3. monta o vídeo 1080x1920 com FFmpeg (Ken Burns + legendas queimadas);
  4. devolve o final.mp4 como binário.

Endpoints:
  GET  /health      -> {"ok": true, ...}
  POST /selftest    -> gera assets de teste e devolve final.mp4 (valida o pipeline isolado)
  POST /render      -> devolve video/mp4
  POST /thumbnail   -> devolve image/jpeg

Auth: se RENDER_TOKEN estiver setada, exige header  X-Render-Token: <token>  (exceto /health).

Env relevantes:
  RENDER_TOKEN     token de acesso (recomendado)
  OPENAI_API_KEY   p/ transcrição Whisper (transcribe=openai)
  PEXELS_API_KEY   p/ buscar imagens a partir de termos
"""
import glob
import json
import os
import subprocess
import tempfile

import requests
from flask import Flask, request, send_file, jsonify, abort

app = Flask(__name__)
HERE = os.path.dirname(os.path.abspath(__file__))

VERSION = "8-musica-debug"
MUSIC_DIR = os.environ.get("MUSIC_DIR", "/app/music")
TOKEN = os.environ.get("RENDER_TOKEN", "")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
PEXELS_API_KEY = os.environ.get("PEXELS_API_KEY", "")
DOWNLOAD_TIMEOUT = int(os.environ.get("DOWNLOAD_TIMEOUT", "60"))
# b-roll em video do Pexels. PADRAO DESLIGADO: pesado demais p/ VPS de 1 nucleo.
# Ligue (PREFER_VIDEO=1) so se subir o VPS p/ 2+ vCPU.
PREFER_VIDEO = os.environ.get("PREFER_VIDEO", "0") not in ("0", "false", "")


def _check_auth():
    if TOKEN and request.headers.get("X-Render-Token", "") != TOKEN:
        abort(401, description="token inválido")


def _run(script, *args):
    proc = subprocess.run(
        ["bash", os.path.join(HERE, script), *args],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"{script} falhou (exit {proc.returncode})\n"
            f"--- STDOUT ---\n{proc.stdout}\n--- STDERR ---\n{proc.stderr}"
        )
    return proc.stdout + proc.stderr


def _duration(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", path],
        capture_output=True, text=True,
    )
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def _pexels_search(term):
    """Retorna a URL (src.large) da 1a foto vertical para o termo, ou None."""
    if not PEXELS_API_KEY:
        return None
    try:
        r = requests.get(
            "https://api.pexels.com/v1/search",
            params={"query": term, "per_page": 1, "orientation": "portrait"},
            headers={"Authorization": PEXELS_API_KEY},
            timeout=DOWNLOAD_TIMEOUT,
        )
        r.raise_for_status()
        photos = r.json().get("photos", [])
        if photos:
            src = photos[0]["src"]
            # large2x tem mais resolucao (menos amador) com fallback p/ large/original
            return src.get("large2x") or src.get("original") or src.get("large")
    except Exception as e:  # noqa: BLE001
        app.logger.warning("pexels falhou p/ '%s': %s", term, e)
    return None


def _pexels_video_search(term):
    """Retorna o link de um vídeo vertical do Pexels para o termo, ou None."""
    if not PEXELS_API_KEY:
        return None
    try:
        r = requests.get(
            "https://api.pexels.com/videos/search",
            params={"query": term, "per_page": 1, "orientation": "portrait",
                    "size": "small"},
            headers={"Authorization": PEXELS_API_KEY},
            timeout=DOWNLOAD_TIMEOUT,
        )
        r.raise_for_status()
        vids = r.json().get("videos", [])
        if not vids:
            return None
        files = vids[0].get("video_files", [])
        # prefere arquivos verticais (altura >= largura)
        portrait = [f for f in files if (f.get("height") or 0) >= (f.get("width") or 0)]
        cand = portrait or files
        if not cand:
            return None
        cand.sort(key=lambda f: f.get("height") or 0)
        # menor arquivo com altura >= 720: leve p/ baixar/decodificar (vira fundo, escala p/ 1080)
        chosen = next((f for f in cand if (f.get("height") or 0) >= 720), cand[-1])
        return chosen.get("link")
    except Exception as e:  # noqa: BLE001
        app.logger.warning("pexels video falhou p/ '%s': %s", term, e)
        return None


def _download(url, path):
    r = requests.get(url, timeout=DOWNLOAD_TIMEOUT,
                     headers={"User-Agent": "Mozilla/5.0 (render-service)"})
    r.raise_for_status()
    with open(path, "wb") as f:
        f.write(r.content)


def _resolve_media(workdir, image_urls, pexels_terms):
    """Resolve cada termo em b-roll de vídeo (preferido) ou foto do Pexels,
    salvando como media_NNN.mp4 / media_NNN.jpg na ordem. URLs diretas viram fotos."""
    idx = len(glob.glob(os.path.join(workdir, "media_*")))
    for term in (pexels_terms or []):
        if PREFER_VIDEO:
            vurl = _pexels_video_search(term)
            if vurl:
                try:
                    _download(vurl, os.path.join(workdir, f"media_{idx:03d}.mp4"))
                    idx += 1
                    continue
                except Exception as e:  # noqa: BLE001
                    app.logger.warning("falha ao baixar video %s: %s", vurl, e)
        purl = _pexels_search(term)
        if purl:
            try:
                _download(purl, os.path.join(workdir, f"media_{idx:03d}.jpg"))
                idx += 1
            except Exception as e:  # noqa: BLE001
                app.logger.warning("falha ao baixar foto %s: %s", purl, e)
    for u in (image_urls or []):
        try:
            _download(u, os.path.join(workdir, f"media_{idx:03d}.jpg"))
            idx += 1
        except Exception as e:  # noqa: BLE001
            app.logger.warning("falha ao baixar %s: %s", u, e)
    return idx


def _ensure_one_image(workdir):
    if not glob.glob(os.path.join(workdir, "media_*")) and not glob.glob(os.path.join(workdir, "img_*")):
        subprocess.run(["ffmpeg", "-y", "-f", "lavfi",
                        "-i", "color=c=0x111827:s=1080x1920:d=1",
                        "-frames:v", "1", os.path.join(workdir, "media_000.jpg")],
                       capture_output=True)


def _transcribe_openai(audio_path, language="pt"):
    """Transcreve via OpenAI Whisper, retorna SRT (texto) ou None."""
    if not OPENAI_API_KEY:
        return None
    try:
        with open(audio_path, "rb") as f:
            r = requests.post(
                "https://api.openai.com/v1/audio/transcriptions",
                headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
                files={"file": ("narration.mp3", f, "audio/mpeg")},
                data={"model": "whisper-1", "response_format": "srt",
                      "language": language},
                timeout=120,
            )
        r.raise_for_status()
        return r.text
    except Exception as e:  # noqa: BLE001
        app.logger.warning("whisper falhou: %s", e)
        return None


def _form_json(field):
    raw = request.form.get(field, "")
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        abort(400, description=f"'{field}' não é JSON válido")


@app.get("/health")
def health():
    import shutil
    music = (glob.glob(os.path.join(MUSIC_DIR, "*.mp3"))
             + glob.glob(os.path.join(MUSIC_DIR, "*.m4a"))
             + glob.glob(os.path.join(MUSIC_DIR, "*.wav")))
    return jsonify(ok=True,
                   version=VERSION,
                   prefer_video=PREFER_VIDEO,
                   music_files=len(music),
                   music_names=[os.path.basename(m) for m in music],
                   ffmpeg=shutil.which("ffmpeg") is not None,
                   openai=bool(OPENAI_API_KEY),
                   pexels=bool(PEXELS_API_KEY))


@app.post("/selftest")
def selftest():
    _check_auth()
    workdir = tempfile.mkdtemp(prefix="selftest_")
    try:
        log = _run("selftest.sh", workdir)
        final = os.path.join(workdir, "final.mp4")
        if not os.path.exists(final):
            return jsonify(ok=False, log=log), 500
        return send_file(final, mimetype="video/mp4",
                         as_attachment=True, download_name="selftest.mp4")
    except RuntimeError as e:
        return jsonify(ok=False, error=str(e)), 500


@app.post("/render")
def render():
    """multipart:
       audio          file   (narration.mp3, obrigatório)
       pexels_terms   text   JSON array de termos de busca (serviço busca no Pexels)
       image_urls     text   JSON array de URLs já resolvidas (alternativa)
       srt            text   legendas prontas (alternativa à transcrição)
       transcribe     text   "openai" p/ transcrever o áudio via Whisper
    """
    _check_auth()
    workdir = tempfile.mkdtemp(prefix="render_")
    if "audio" not in request.files:
        return jsonify(ok=False, error="campo 'audio' (file) ausente"), 400
    audio_path = os.path.join(workdir, "narration.mp3")
    request.files["audio"].save(audio_path)

    # mídia (b-roll de vídeo preferido, cai p/ foto)
    _resolve_media(workdir, _form_json("image_urls"), _form_json("pexels_terms"))
    _ensure_one_image(workdir)

    # legendas: srt explícito tem prioridade; senão transcreve se pedido
    srt = request.form.get("srt", "")
    if not srt.strip() and request.form.get("transcribe", "") == "openai":
        srt = _transcribe_openai(audio_path) or ""
    if srt.strip():
        with open(os.path.join(workdir, "subs.srt"), "w", encoding="utf-8") as f:
            f.write(srt)

    try:
        _run("montar.sh", workdir)
    except RuntimeError as e:
        return jsonify(ok=False, error=str(e)), 500

    final = os.path.join(workdir, "final.mp4")
    if not os.path.exists(final):
        return jsonify(ok=False, error="final.mp4 não foi gerado"), 500
    resp = send_file(final, mimetype="video/mp4",
                     as_attachment=True, download_name="final.mp4")
    resp.headers["X-Duration"] = str(_duration(final))
    return resp


@app.post("/thumbnail")
def thumbnail():
    """multipart: (pexels_term | image_url) + text"""
    _check_auth()
    workdir = tempfile.mkdtemp(prefix="thumb_")
    term = request.form.get("pexels_term", "")
    url = request.form.get("image_url", "")
    try:
        if "img0" in request.files:
            request.files["img0"].save(os.path.join(workdir, "img_000.jpg"))
        elif url:
            _download(url, os.path.join(workdir, "img_000.jpg"))
        elif term:
            u = _pexels_search(term)
            if not u:
                return jsonify(ok=False, error="pexels não retornou imagem"), 502
            _download(u, os.path.join(workdir, "img_000.jpg"))
        else:
            return jsonify(ok=False, error="envie pexels_term, image_url ou img0"), 400
        _run("thumb.sh", workdir, request.form.get("text", ""))
    except RuntimeError as e:
        return jsonify(ok=False, error=str(e)), 500
    thumb = os.path.join(workdir, "thumb.jpg")
    if not os.path.exists(thumb):
        return jsonify(ok=False, error="thumb.jpg não foi gerado"), 500
    return send_file(thumb, mimetype="image/jpeg",
                     as_attachment=True, download_name="thumb.jpg")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8088")))
