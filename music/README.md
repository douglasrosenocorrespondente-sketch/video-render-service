# Música de fundo

Coloque aqui **1 ou mais arquivos `.mp3`** de música **sem copyright** (livre para YouTube).
O render escolhe um aleatoriamente e mixa em volume baixo (padrão 12%) sob a narração.
Se a pasta estiver vazia (só este README), o vídeo sai **sem** música — sem erro.

## Onde pegar música segura (sem Content ID / strike)
- **YouTube Studio → Biblioteca de áudio** (a mais segura p/ YouTube; filtre por "Sem atribuição").
- **Pixabay Music** (pixabay.com/music) — licença livre.
- Evite música comercial/Spotify — derruba o vídeo por direitos autorais.

## Como adicionar
1. Baixe o `.mp3` e jogue nesta pasta `music/`.
2. `git add . && git commit -m "trilha de fundo" && git push`
3. Rebuild do serviço no easypanel.

## Ajustar o volume
Variável de ambiente `MUSIC_VOLUME` (padrão `0.12`). Ex.: `0.08` = mais baixo, `0.2` = mais alto.
