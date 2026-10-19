# hexvision

[English](README.md) · **Português**

O lado do robô no "Siga-me" (ADR-0017 e o roadmap): o hexvision lê a câmera, acha os alvos e manda para o hexd, que repassa ao app. O app desenha um quadro em cada alvo sobre o vídeo; o piloto toca num deles e manda seguir.

```
câmera -> MediaMTX (rtsp://127.0.0.1:8554/cam) -> hexvision -> UDP 127.0.0.1:47300 -> hexd -> app
```

- **Pessoas:** MobileNet-SSD (licença MIT) pelo módulo dnn do OpenCV. Um rastreador mantém o mesmo número na mesma pessoa de um quadro para o outro e a reconhece pelas cores da roupa depois de sumir por um instante.
- **Marcadores ArUco** (`DICT_4X4_50`), por exemplo na tela do celular: só para perto (~1 m medido com a tela de um celular; um marcador impresso em A4 chega a ~4 m).
- **Por alvo:** quadro na imagem, ângulo (+ = esquerda do robô), elevação e distância (de uma pessoa, pela altura do corpo inteiro; de um marcador, pelo tamanho).
- **Sem alarme falso:** um alvo só chega ao app depois de 3 quadros seguidos.
- **Processo separado** do hexd: se a visão parar ou travar, a ligação com o ESP32 nem percebe.
- **Nada se move por aqui.** Seguir (F2) transforma o alvo travado em Commands no hexd, sempre sob o failsafe do ESP32.

## No PC, com webcam

```bash
cd proto && buf generate --template buf.gen.vision.yaml      # mensagens em Python (precisa do protoc)
cd ../pi/hexvision
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
./get_models.sh                                              # detector de pessoas (23 MB, conferido pelo SHA-256)
.venv/bin/python -m hexvision --source 0 --show --models models   # 0 = primeira webcam; Esc sai
.venv/bin/python -m unittest discover -s tests -t .          # testes (imagens sintéticas)
```

Fique na frente da webcam (ou mostre um marcador `DICT_4X4_50`): a janela mostra o quadro, o ângulo e a distância. Com o hexd rodando no mesmo PC, os alvos também chegam ao app.

## No robô

Instalado pelo deploy (`/opt/hexapod/current/hexvision`) e rodado pelo `hexvision.service` (prioridade abaixo do hexd, no máximo 1,5 núcleo). O Ansible instala `python3-opencv` e `python3-protobuf` e baixa o detector de pessoas para `/opt/hexapod/shared/models/mobilenet-ssd` (sem ele, só marcadores).

| Opção | Padrão | |
|---|---|---|
| `--source` | `rtsp://127.0.0.1:8554/cam` | URL da câmera ou número da webcam |
| `--width` | 960 | largura processada (um marcador na tela do celular precisa de ~7 px de lado) |
| `--fps` | 15 | no máximo |
| `--hfov` | 100 | campo de visão horizontal sem calibração da lente, graus |
| `--calibration` | `/opt/hexapod/shared/config/camera_calibration.json` | calibração da lente (F0): ângulos e distâncias medidos, não estimados |
| `--marker-size` | 0.05 | quadrado preto do marcador, m |
| `--models` | `/opt/hexapod/shared/models/mobilenet-ssd` | detector de pessoas |
| `--people-min` | 0.5 | confiança mínima do detector de pessoas, 0..1 |

Custo: o detector de pessoas leva ~30 ms por quadro num núcleo de um PC de mesa; um núcleo do Pi 3 é 10 a 15 vezes mais lento (a medir no robô), e o Pi 4 umas 3 vezes mais rápido que o Pi 3.
