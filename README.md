# video-render-service

Serviço HTTP isolado que monta o vídeo vertical (1080x1920) do canal de notícias
esportivas usando **FFmpeg**. Existe porque a instância n8n do easypanel é
**read-only e sem `Execute Command`** — o n8n não roda shell nem grava em disco.
Então o n8n só orquestra (em memória) e chama este serviço por HTTP.

```
n8n  --(audio mp3 + URLs de imagens + .srt)-->  [video-render-service]  --(final.mp4)-->  n8n
```

## Arquivos
- `app.py` — servidor Flask (endpoints `/health`, `/selftest`, `/render`, `/thumbnail`)
- `montar.sh` — pipeline FFmpeg: imagens → clipes com Ken Burns → concat → áudio + legendas
- `thumb.sh` — gera `thumb.jpg` 1280x720 com texto
- `selftest.sh` — gera assets sintéticos e roda o pipeline (valida tudo isolado)
- `Dockerfile`, `requirements.txt`

---

## 1. Deploy no easypanel

1. No easypanel: **+ Create** → **App** (serviço novo, separado do n8n — não mexe no n8n).
2. **Source**: aponte para um repositório Git com esta pasta, **ou** use "Dockerfile"
   colando o conteúdo. (Se usar Git, faça commit desta pasta `video-render-service/`.)
3. **Build**: tipo Dockerfile (o easypanel detecta o `Dockerfile`).
4. **Environment**: defina as variáveis:
   ```
   RENDER_TOKEN=<gere-um-token-aleatorio-longo>     # protege o serviço
   OPENAI_API_KEY=<sua-chave-openai>                # p/ legendas (Whisper)
   PEXELS_API_KEY=<sua-chave-pexels>                # p/ buscar as imagens
   ```
   (O serviço busca as imagens no Pexels e transcreve o áudio sozinho — por isso
   essas chaves ficam aqui, e não no n8n.)
5. **Port**: `8088` (o container expõe nessa porta).
6. Deixe **sem domínio público** se quiser que só o n8n acesse (comunicação interna
   pelo nome do serviço). Se publicar um domínio, o `RENDER_TOKEN` é o que protege.
7. Deploy. O primeiro build baixa o ffmpeg (~alguns minutos).

> **URL interna** para o n8n usar: no easypanel os serviços do mesmo projeto se
> enxergam pelo nome, algo como `http://video-render-service:8088`. Confirme o
> hostname exato na aba de rede/serviço.

---

## 2. Teste isolado (faça isto PRIMEIRO — é a etapa que mais dá trabalho)

Depois do deploy, valide que o FFmpeg monta um vídeo correto **antes de plugar o n8n**:

```bash
# troque a URL/token pelos seus
curl -X POST https://SEU-SERVICO/selftest \
  -H "X-Render-Token: SEU_TOKEN" \
  -o selftest.mp4
```

Abra `selftest.mp4`: deve ter ~6s, 1080x1920, 3 telas coloridas com zoom suave,
um tom de áudio e duas legendas. Se isso funcionar, **70% do projeto está de pé.**

Health check rápido:
```bash
curl https://SEU-SERVICO/health     # {"ok": true, "ffmpeg": true}
```

---

## 3. Endpoints (como o n8n chama)

### `POST /render` → devolve `video/mp4`
multipart/form-data (header `X-Render-Token: <token>`):
| campo | tipo | descrição |
|---|---|---|
| `audio` | file | narration.mp3 (binário vindo do ElevenLabs) — **obrigatório** |
| `pexels_terms` | text | JSON array de termos em inglês; o serviço busca no Pexels. Ex: `["soccer stadium crowd","brazil flag fans"]` |
| `image_urls` | text | JSON array de URLs já resolvidas (alternativa ao `pexels_terms`) |
| `transcribe` | text | `openai` → transcreve o áudio via Whisper e queima as legendas |
| `srt` | text | legendas prontas em SRT (alternativa ao `transcribe`) |

Resposta: binário do mp4 + header `X-Duration`.

### `POST /thumbnail` → devolve `image/jpeg`
multipart: `pexels_term` (text) **ou** `image_url` (text) + `text` (texto da thumb).

---

## 4. Fonte "Anton" (opcional, visual mais "esportivo")
A imagem já vem com DejaVu (funciona). Para usar Anton:
1. Baixe `Anton.ttf` para esta pasta.
2. No `Dockerfile`, descomente as linhas `COPY Anton.ttf ...` e `RUN fc-cache -f`.
3. Defina envs `FONT_NAME=Anton` e `FONT_FILE=/usr/share/fonts/truetype/anton/Anton.ttf`.
4. Rebuild.

---

## 5. Ajuste fino do visual
O efeito Ken Burns e o estilo das legendas estão em `montar.sh` (passos 1 e 3).
São o ponto de partida — depois de ver o primeiro vídeo real, dá pra calibrar
velocidade do zoom, tamanho/posição da legenda, etc.
