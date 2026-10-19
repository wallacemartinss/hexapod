# hexvision

[English](README.md) · **Português**

O lado do robô no "Siga-me" (ADR-0017 e o roadmap): o hexvision lê a câmera, acha os alvos e manda para o hexd, que repassa ao app. O app desenha um quadro em cada alvo sobre o vídeo; o piloto toca num deles e manda seguir.

```
câmera -> MediaMTX (rtsp://127.0.0.1:8554/cam) -> hexvision -> UDP 127.0.0.1:47300 -> hexd -> app
```

- **Alvos por enquanto:** marcadores ArUco (`DICT_4X4_50`), por exemplo na tela do celular. Pessoas depois (Pi 4).
- **Por alvo:** quadro na imagem, ângulo (+ = esquerda do robô), elevação e distância (pelo tamanho do marcador, `--marker-size`).
- **Processo separado** do hexd: se a visão parar ou travar, a ligação com o ESP32 nem percebe.
- **Nada se move por aqui.** Seguir (F2) transforma o alvo travado em Commands no hexd, sempre sob o failsafe do ESP32.

## No PC, com webcam

```bash
cd proto && buf generate --template buf.gen.vision.yaml      # mensagens em Python (precisa do protoc)
cd ../pi/hexvision
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m hexvision --source 0 --show              # 0 = primeira webcam; Esc sai
.venv/bin/python -m unittest discover -s tests -t .          # testes (imagens sintéticas)
```

Mostre um marcador para a webcam (qualquer `DICT_4X4_50`, por exemplo no celular): a janela mostra o quadro, o ângulo e a distância. Com o hexd rodando no mesmo PC, os alvos também chegam ao app.

## No robô

Instalado pelo deploy (`/opt/hexapod/current/hexvision`) e rodado pelo `hexvision.service` (prioridade abaixo do hexd, no máximo 1,5 núcleo). O Ansible instala `python3-opencv` e `python3-protobuf`.

| Opção | Padrão | |
|---|---|---|
| `--source` | `rtsp://127.0.0.1:8554/cam` | URL da câmera ou número da webcam |
| `--width` | 960 | largura processada (um marcador na tela do celular precisa de ~7 px de lado) |
| `--fps` | 15 | no máximo |
| `--hfov` | 100 | campo de visão horizontal sem calibração da lente, graus |
| `--calibration` | `/opt/hexapod/shared/config/camera_calibration.json` | calibração da lente (F0): ângulos e distâncias medidos, não estimados |
| `--marker-size` | 0.05 | quadrado preto do marcador, m |
