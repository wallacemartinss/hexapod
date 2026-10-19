# hexvision

[English](README.md) · **Português**

O lado do robô no "Siga-me" (ADR-0017 e o roadmap): o hexvision lê a câmera, acha os alvos e manda para o hexd, que repassa ao app. O app desenha um quadro em cada alvo sobre o vídeo; o piloto toca num deles e manda seguir.

```
câmera -> MediaMTX (rtsp://127.0.0.1:8554/cam) -> hexvision -> UDP 127.0.0.1:47300 -> hexd -> app
```

- **Pessoas e animais (cães e gatos):** MobileNet-SSD (licença MIT) pelo módulo dnn do OpenCV; um animal só é medido pelos pés (não há altura típica). Um rastreador mantém o mesmo número na mesma pessoa de um quadro para o outro e a reconhece pelas cores da roupa depois de sumir por um instante.
- **Marcadores ArUco** (`DICT_4X4_50`), por exemplo na tela do celular: só para perto (~1 m medido com a tela de um celular; um marcador impresso em A4 chega a ~4 m).
- **Por alvo:** quadro na imagem, ângulo (+ = esquerda do robô), elevação e distância (de um marcador, pelo tamanho; de uma pessoa, pelo ponto em que os pés tocam o chão, o que funciona de perto mesmo com a cabeça fora da imagem, ou então pela altura do corpo inteiro).
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
| `--calibration` | `/opt/hexapod/shared/config/camera_calibration.json` | calibração da lente: ângulos e distâncias medidos, não estimados |
| `--marker-size` | 0.05 | quadrado preto do marcador, m |
| `--models` | `/opt/hexapod/shared/models/mobilenet-ssd` | detector de pessoas |
| `--camera-height` | 0.15 | altura da câmera em relação ao chão, m (distância da pessoa pelos pés) |
| `--camera-pitch` | 0 | inclinação da câmera, graus (+ = para cima) |
| `--people-min` | 0.5 | confiança mínima do detector de pessoas, 0..1 |
| `--detect-interval` | 0 | s no mínimo entre detecções de pessoas (economiza CPU; o rastreador rápido cobre os intervalos) |

Custo, medido: o detector de pessoas leva 30 ms por quadro num núcleo de PC de mesa e ~630 ms no Pi 3 (4 núcleos, com a CPU freada por subtensão); por isso ele roda numa linha de execução própria e, entre uma detecção e outra, um rastreador MOSSE move o quadro de cada pessoa a cada quadro (~1 ms no Pi 3). Marcadores: 87 ms por quadro em 960x720 no Pi 3.

No hexd, com o alvo bem à frente (até 10 graus), o VL53L0X da frente também o mede: vale a menor das duas distâncias, então algo entre o robô e o alvo faz ele frear.

## Lacunas conhecidas (débito técnico)

- **Calibração da lente:** ainda não há ferramenta para gerar o `camera_calibration.json` (fotos de um tabuleiro de xadrez e `cv2.calibrateCamera`). Sem ela, a lente de 120 graus é tratada como pinhole, e ângulos e distâncias erram alguns graus e centímetros perto das bordas da imagem.
- **Altura e inclinação da câmera:** `--camera-height` e `--camera-pitch` são provisórios até serem medidos no robô montado; a altura do próprio corpo e o balanço ao andar não entram na conta.
