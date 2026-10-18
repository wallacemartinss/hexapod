# CLAUDE.md: Hexápode aranha

> Coloque este arquivo na raiz do repositório `hexapod/`. O Claude Code lê o `CLAUDE.md` automaticamente ao abrir o projeto.
> Documentação e mensagens para o usuário em **português**. Código, nomes de arquivos, identificadores e commits em **inglês**.

## 1. Contexto do projeto

Robô hexápode impresso em 3D (base: "Hexapod Spider Robot with Servo & Arduino", MakerWorld), com 18 servos MG996R e 3 graus de liberdade por perna. Ele é controlado por um app Flutter via Wi-Fi e, no futuro, também por 4G.

**O hardware ainda está chegando.** Tudo o que puder ser desenvolvido e testado **sem hardware** vem primeiro: simulador, testes nativos e mocks.

### Hardware definido

| Função | Componente | Observação |
|---|---|---|
| Ponte, vídeo e rede | Raspberry Pi 3 Model B v1.2 | Raspberry Pi OS Lite 64-bit. Wi-Fi só 2,4 GHz (802.11n) |
| Tempo real | ESP32-S3 SuperMini | USB nativa (VID:PID `303a:1001`) ligada ao Pi |
| Tempo real (só bancada, temporário) | ESP32 DevKit 38 pinos, ESP-WROOM-32 (ESP32-D0WDQ6, 4 MB) | USB via CP2102 (`10c4:ea60`). PlatformIO `esp32dev`. GPIO6–11 = flash (proibidos); 34–39 só entrada |
| Olhos (fase futura) | 2nd ESP32-S3 SuperMini + 2x GC9A01 1,28" | Recebe comandos simples do ESP32 principal |
| Servos | 2x PCA9685 (HW-170), endereços 0x40 e 0x41 | Nº 1: pernas esquerdas; nº 2: pernas direitas |
| IMU | BNO085 | Usar *game rotation vector* (sem magnetômetro) por padrão |
| Distância | 4x VL53L0X (GY-VL53L0XV2) | Todos com 0x29 de fábrica: trocar no boot via XSHUT para 0x30–0x33 |
| Ambiente | BME280 (0x76) | |
| Bateria | INA226 (0x40) | **Ver o aviso sobre o shunt na seção 9** |
| Câmera | OV5647, grande-angular 120° | Porta CSI, H.264 por hardware |
| Áudio | Mini microfone USB | Plugado direto no Pi |
| LEDs | WS2812 (decisão pendente; antes eram LEDs de 1 W com PT4115) | Um pino de dados |
| Energia dos servos | Step-down de 20 A (15 A sugeridos), ajustado em 6,0 V | Alimenta o V+ das duas PCA9685 |
| Energia da lógica | Mini560 Pro 5 V / 5 A | Pi pelo GPIO (pinos 2/6), ESP32 e sensores |
| Bateria | LiPo 3S 2200 mAh, XT60 | Fusível de 20 A + chave anti-spark |

**Fora do projeto:** GPS, MQ-2, JSN-SR04T, VL53L1X.

### Barramentos

- **I2C 0 (servos, 400 kHz):** PCA9685 0x40 e 0x41.
- **I2C 1 (sensores):** VL53L0X 0x30–0x33, BNO085 0x4A, BME280 0x76, INA226 0x40.
- **USB:** ESP32 ↔ Pi (protocolo + gravação do firmware).
- **GPIO do ESP32:** 4x XSHUT, OE das PCA9685 (ligado ao das duas placas: corte de emergência), dados dos WS2812, interrupção do BNO085 (opcional) e UART para o ESP32 dos olhos (futuro).
- **Mapa de pinos: definido (v1)** em `firmware/include/pins.h` e documentado em `firmware/PINOUT.md`, para o S3 e para a placa de bancada. Pads do SuperMini ainda a conferir quando a placa chegar.

## 2. Regras de segurança (obrigatórias)

Este código mexe com um robô de ~2,5 kg com 18 servos. Siga sempre:

1. **Nunca gere código que mova servos sem confirmação explícita do usuário** no momento do teste. O padrão do firmware é **servos desligados**: OE das PCA9685 em nível alto e nenhum pulso enviado.
2. **Limites de ângulo por servo** (mínimo, máximo e offset de calibração) ficam salvos na NVS do ESP32. Nenhum comando pode passar desses limites, nem em modo de calibração.
3. **Movimento sempre interpolado:** nunca saltar para uma pose. Use velocidade máxima por junta.
4. **O failsafe fica no ESP32 e não pode ser desligado por comando remoto.** Ver a seção 6.
5. **Deploy só com o robô sentado:** o `deploy.sh` precisa recusar a atualização em qualquer outro estado.
6. **Nada de segredos no repositório:** chave do Tailscale, Wi-Fi e tokens ficam em GitHub Secrets ou em arquivos ignorados pelo git.
7. Antes de qualquer teste com hardware real, **liste o que vai acontecer fisicamente** e espere o "ok" do usuário.

## 3. Estrutura do repositório

```
hexapod/
├─ CLAUDE.md
├─ proto/                 # contrato único (buf)
│  ├─ buf.yaml
│  └─ hexapod/v1/*.proto
├─ firmware/              # ESP32-S3 (PlatformIO, framework Arduino + FreeRTOS)
│  ├─ platformio.ini      # envs: esp32s3, native (testes)
│  ├─ include/            # pins.h, config.h (dimensões das pernas, limites)
│  ├─ src/
│  │  ├─ main.cpp
│  │  ├─ link/            # COBS + CRC16 + nanopb
│  │  ├─ motion/          # ik, gait, pose, interpolator
│  │  ├─ servo/           # driver PCA9685, calibração, limites, NVS
│  │  ├─ sensors/         # vl53l0x, bno085, bme280, ina226
│  │  ├─ safety/          # failsafe (máquina de estados)
│  │  └─ leds/
│  └─ test/               # testes nativos: IK, marcha, failsafe, link
├─ pi/
│  ├─ hexd/               # serviço Go (cmd/hexd, internal/...)
│  ├─ hexsim/             # simulador de ESP32 em Go (fala o mesmo protocolo)
│  ├─ provision/          # Ansible para preparar o Pi
│  ├─ mediamtx/           # mediamtx.yml
│  ├─ systemd/            # hexd.service, mediamtx.service, mic-stream.service
│  └─ deploy/deploy.sh
├─ app/                   # Flutter (fase posterior)
├─ cad/                   # STLs e diagramas
└─ .github/workflows/     # pi.yml, firmware.yml, app.yml
```

## 4. Ordem de trabalho

Execute **uma fase por vez**. Ao terminar cada uma, mostre o resumo e os testes, e espere o usuário.

### Fase 0: estação de trabalho (no PC do usuário)

Verificar ou instalar:
- `git` e `gh`
- Go ≥ 1.22
- PlatformIO Core (`pio`)
- `buf` e `protoc`, com os plugins `protoc-gen-go` e o gerador do nanopb
- Flutter SDK (só na fase 6)
- Raspberry Pi Imager
- Tailscale
- Ansible

Criar o repositório com a estrutura da seção 3, mais `.gitignore` e `README.md` em português.

### Fase 1: preparar o Raspberry Pi

**1.1 Gravação do cartão (manual, instruir o usuário)**
- Raspberry Pi Imager com **Raspberry Pi OS Lite 64-bit**.
- Nas opções avançadas:
  - hostname `hexapod`;
  - usuário e senha;
  - chave SSH pública do PC;
  - Wi-Fi e país `BR`.

**1.2 Provisionamento com Ansible (`pi/provision/`)**

Gerar um playbook idempotente que faça:
- `apt update/upgrade`, instalar `rpicam-apps`, `alsa-utils`, `ffmpeg`, `avahi-daemon`, `git`, `rsync`.
- Câmera: garantir `camera_auto_detect=1` em `/boot/firmware/config.txt`. Se não detectar, usar `dtoverlay=ov5647`.
- Desligar o que não é usado (por exemplo, a saída HDMI) para economizar energia, deixando isso documentado.
- Instalar o **Tailscale** (o `tailscale up` com a auth key fica como passo manual ou via variável não versionada).
- Instalar o **MediaMTX** (binário arm64, versão fixa em variável) com `pi/mediamtx/mediamtx.yml`:
  - caminho `cam` com `source: rpiCamera` (720p, 30 fps, H.264);
  - caminho `mic` publicado por um serviço `ffmpeg` lendo o ALSA do microfone USB e codificando em Opus. **Validar no hardware**; se for melhor juntar vídeo e áudio num caminho só, propor.
- Estrutura de deploy:
  ```
  /opt/hexapod/releases/<versão>/
  /opt/hexapod/current -> releases/<versão>
  /opt/hexapod/shared/{config,logs,firmware}
  ```
- Usuário de serviço `hexapod` nos grupos `dialout` e `video`.
- **Regra udev:** ESP32-S3 (`303a:1001`) → link simbólico `/dev/hexapod-esp32`.
- Units do systemd: `hexd.service`, `mediamtx.service` e `mic-stream.service`, com `Restart=always`.
- Ativar o **watchdog de hardware** do Pi (`RuntimeWatchdogSec` no systemd).
- **NÃO** ativar o sistema de arquivos somente leitura (overlay) agora. Deixe como tarefa da fase 5, depois que o deploy estiver estável.

**1.3 Validação (script `pi/provision/check.sh`)**
- `rpicam-hello --list-cameras` lista a OV5647.
- `arecord -l` lista o microfone USB.
- `vcgencmd get_throttled` retorna `0x0`. Se não, avisar: é subtensão.
- `ls -l /dev/hexapod-esp32` (quando o ESP32 estiver ligado).
- `tailscale status`
- O stream WebRTC do MediaMTX abre no navegador do PC.

### Fase 2: contrato Protobuf (`proto/hexapod/v1/`)

Mensagens mínimas:
- `Hello`: versões do firmware e do hexd, hash do git, uptime.
- `Command`:
  - `seq`, `timestamp_ms`;
  - `vx`, `vy`, `yaw_rate` (normalizados de −1 a 1);
  - `body_height`, `body_roll`, `body_pitch`, `body_yaw`;
  - `gait` (TRIPOD, WAVE, RIPPLE);
  - `mode` (SIT, STAND, WALK, CALIBRATE);
  - `estop`.
- `Telemetry`:
  - `seq`, `state` (NORMAL, STOPPING, SAFE_SIT, RELAXED, BLOCKED, LOW_BATTERY, TIPPED, ESTOP);
  - `fault_flags`;
  - bateria (V, A);
  - orientação (quaternion + roll/pitch/yaw);
  - `distances_mm[4]`;
  - temperatura, umidade e pressão;
  - temperatura do ESP32;
  - `loop_time_us`.
- `CalibrationCommand` e `CalibrationReport`: um servo por vez, offsets e limites.
- `Event`: para o modo pet no futuro (toque, empurrão, aproximação).

Transporte na serial: **COBS** para separar os quadros, com um **CRC16** no fim de cada um e o payload em nanopb. O app fala com o hexd por WebSocket binário, usando o mesmo Protobuf.

Gerar com `buf generate` código Go (`pi/hexd/gen`), nanopb (`firmware/lib/proto`) e Dart (`app/lib/gen`, na fase 6). Definir `max_size` e `max_count` do nanopb nos arquivos `.options`.

### Fase 3: firmware do ESP32 (`firmware/`)

**PlatformIO**
- Ambiente `esp32s3`: placa `esp32-s3-devkitc-1`, `-DARDUINO_USB_CDC_ON_BOOT=1`. Confirmar as configurações de flash e PSRAM do SuperMini comprado.
- Ambiente `native`: testes no PC com Unity, sem hardware.
- Bibliotecas sugeridas (avaliar e travar as versões):
  - Adafruit PWM Servo Driver;
  - Pololu VL53L0X (tem `setAddress`);
  - SparkFun ou Adafruit BNO08x;
  - Adafruit BME280;
  - INA226 de Rob Tillaart;
  - Nanopb;
  - PacketSerial (COBS) ou implementação própria.

**Tarefas do FreeRTOS**

| Tarefa | Núcleo | Frequência | Função |
|---|---|---|---|
| `motion` | 1 | 50 Hz fixos | Failsafe → marcha → IK → limites → PCA9685 |
| `sensors` | 0 | 10–20 Hz | VL53L0X (em sequência), BNO085, BME280, INA226 |
| `link` | 0 | por evento | Recebe `Command`, envia `Telemetry` a 10 Hz e `Hello` |
| `leds` | 0 | 30 Hz | Padrões conforme o estado |

**Módulos**
- `motion/ik`:
  - cinemática inversa de 3 graus de liberdade por perna;
  - dimensões (coxa, fêmur, tíbia) e posição de cada perna em `config.h`.
  - **As dimensões ainda não foram medidas.** Deixe-as como constantes marcadas com `TODO` e, se os STL das pernas estiverem em `cad/`, meça-os com um script Python (trimesh) e proponha os valores.
- `motion/gait`: tripé primeiro, depois onda e ripple. Gerador paramétrico (passada, altura do passo, período).
- `motion/pose`: biblioteca de poses (sentar, levantar, relaxar) com interpolação.
- `servo/`: mapeamento de canal → perna e junta, inversão de sentido, offset, mínimo e máximo, tudo gravado na NVS. Também a leitura dos registradores da PCA9685 no boot, para continuar da posição atual (sem pulo depois de um reset).
- `safety/`: ver a seção 6.

**Primeiro marco (sem servos ligados)**
- O firmware inicia com o OE em alto.
- Lê e publica os sensores pela serial.
- Responde ao `Hello`.
- Executa a marcha "no papel", com telemetria dos ângulos calculados.

**Testes nativos obrigatórios**
- A IK devolve ângulos dentro dos limites para todo o espaço de trabalho.
- A IK direta e a inversa batem (ida e volta).
- Na marcha tripé, sempre há 3 pernas no chão.
- Failsafe: todas as transições de estado.
- COBS e CRC: quadros corrompidos são descartados.

### Fase 4: hexd e hexsim (`pi/`)

**hexd (Go)**
- **Serial:** `go.bug.st/serial` em `/dev/hexapod-esp32`, com reconexão automática.
- **Estado:** última telemetria, versão do firmware e conectividade.
- **WebSocket:** `github.com/coder/websocket` em `/ws`, com Protobuf binário.
  - Repassa `Command` do app ao ESP32, carimbando a sequência.
  - Se o app ficar mudo por mais de 150 ms (Wi-Fi) ou 400 ms (4G, detectado pela interface de rede), para de repassar e envia um `Command` de velocidade zero. Quem garante a parada é o ESP32.
- **Endpoints HTTP:**
  - `/health`: 200 só se o ESP32 respondeu nos últimos 2 s;
  - `/version`;
  - `/metrics`: Prometheus com bateria, corrente, estado, distâncias, `loop_time_us`, temperatura do Pi e do ESP32, e RSSI do Wi-Fi.
- **Desligamento seguro:** com bateria crítica e o robô já sentado, executar `systemctl poweroff`.
- **Configuração:** em YAML (`/opt/hexapod/shared/config/hexd.yaml`).
- **Testes:** unitários e de integração contra o `hexsim`.

**hexsim (Go)**
- Simula o ESP32 numa porta serial virtual (`socat`) ou num socket local, com o mesmo protocolo.
- Gera telemetria plausível e implementa o failsafe, para testar o hexd e o app sem hardware.

### Fase 5: esteira de deploy

**`pi/deploy/deploy.sh <pacote.tar.gz>`**
1. Consulta o estado no hexd e **aborta se não estiver em `SAFE_SIT` ou `RELAXED`**.
2. Extrai o pacote em `releases/<versão>`.
3. Se houver firmware novo, grava com `esptool` (através do `/dev/hexapod-esp32`). Guarda o firmware anterior em `shared/firmware/`.
4. Troca o link `current` e executa `systemctl restart hexd`.
5. **Verificação:** em até 10 s, o `Hello` precisa mostrar o firmware novo e o `/health` precisa responder 200.
6. Se a verificação falhar, faz **rollback**: link anterior + regravação do firmware anterior.
7. Mantém as últimas 5 versões.

**Workflows (GitHub Actions)**
- `pi.yml`: testes Go, compilação cruzada `GOOS=linux GOARCH=arm64`, pacote.
- `firmware.yml`: `pio test -e native` + `pio run -e esp32s3`.
- Gatilho do deploy: `workflow_dispatch` (botão manual). Entra na tailnet com a action oficial do Tailscale e envia o pacote por SSH.
- Versão = tag ou hash curto do commit, gravada no binário e no firmware.

Depois do deploy estável: ativar o sistema de arquivos somente leitura (overlay) mantendo `/opt/hexapod` numa partição gravável. Documentar o procedimento.

### Fase 6: app Flutter (`app/`)

- Conexão por mDNS (`hexapod.local`) ou pelo endereço do Tailscale.
- Tela de pilotagem: 2 joysticks virtuais, botões de modo (sentar, levantar, andar) e um botão grande de **PARAR** (`estop`).
- Indicador de estado e motivo (vindos do `Telemetry.state`).
- Telemetria básica e radar dos 4 VL53L0X.
- Envio de `Command` a 20 Hz **mesmo com o joystick parado** (homem-morto).
- Vídeo por `flutter_webrtc` (WHEP do MediaMTX) depois que o controle estiver estável.
- Estado com Riverpod. Testar contra o `hexsim` antes do robô real.

## 5. Convenções

- **Commits** no formato Conventional Commits (`feat(firmware): ...`).
- **Uma branch por fase.** PR com descrição em português.
- **Go:** `gofmt`, `go vet`, `golangci-lint`.
- **C++:** `clang-format` (estilo Google, 2 espaços), sem alocação dinâmica dentro do laço de movimento.
- **Constantes físicas** (dimensões, limites, tempos) ficam em um lugar só (`config.h` / `hexd.yaml`), comentadas com a unidade.

## 6. Failsafe (especificação)

Implementado no ESP32, verificado a cada ciclo de 50 Hz. "Comando válido" = CRC correto e `seq` maior que o último aceito.

| Sem comando válido há | Wi-Fi | 4G | Ação |
|---|---|---|---|
| até | 150 ms | 400 ms | Nada |
| após | 150 ms | 400 ms | Desacelerar até zero em ~300 ms (`STOPPING`) |
| após | 500 ms | 1,5 s | Terminar o passo, apoiar as 6 patas, baixar o corpo (`SAFE_SIT`) |
| após | 10 s | 10 s | Aliviar o torque (`RELAXED`) |

O perfil (Wi-Fi ou 4G) é informado pelo hexd e só pode ser trocado com o robô sentado.

**Outros gatilhos**
- **Inclinação > 35°:** `TIPPED`, relaxa as pernas.
- **VL53L0X < 150 mm:** bloqueia a velocidade naquela direção (`BLOCKED`); as outras direções continuam liberadas.
- **Bateria < 3,5 V/célula:** reduz a velocidade.
- **Bateria < 3,3 V/célula:** `LOW_BATTERY` → sentar e pedir o desligamento do Pi.
- **Corrente alta por mais de 3 s:** sentar e sinalizar a falha.
- **`estop`:** OE em alto na hora.

**Recuperação:** nunca automática. Exige um `Command` com `mode = STAND` depois que o link voltar.

**Watchdog de tarefas do ESP32 ativo.** Depois de um reset, ler as PCA9685 e retomar dali.

## 7. Itens pendentes do usuário (não chute, pergunte)

- [x] Pi 3 Model B v1.2 (Wi-Fi só 2,4 GHz, sem 5 GHz)
- [x] Mapa de pinos (v1, `firmware/PINOUT.md`); conferir os pads do SuperMini quando chegar
- [x] Pernas: 0–2 esquerda, 3–5 direita, da frente para trás. VL53L0X: 0 frente, 1 direita, 2 trás, 3 esquerda
- [x] Dimensões das pernas: coxa 38,07 / fêmur 86,27 / tíbia 163,02 mm, medidas dos STLs (`cad/README.md`, `cad/measure_legs.py`)
- [ ] Qual lado é a frente do corpo (assumido +x, pernas a ±30°)
- [ ] Furação real da câmera e da PCA9685
- [ ] Resistor de shunt do INA226 (ver a seção 9)
- [ ] LEDs: WS2812 ou 1 W
- [ ] Modelo do modem 4G (fase futura)

## 8. Primeiro teste com hardware (roteiro para o usuário)

1. Step-down **sem carga**: ajustar para 6,0 V no multímetro. Mini560: conferir os 5,0–5,2 V.
2. Pi sozinho: `vcgencmd get_throttled` = `0x0`.
3. ESP32 conectado: o `/dev/hexapod-esp32` aparece e a telemetria chega.
4. **Um servo** solto (fora do robô) no canal 0, em modo de calibração, centro em 90°.
5. Calibrar os 18 servos com as pernas **sem** o robô apoiado no chão.
6. Só então ficar em pé, com a mão perto do botão de PARAR.

## 9. Aviso de hardware: shunt do INA226

A maioria dos módulos INA226 vem com shunt de **0,1 Ω (R100)**. Com ele, o máximo mensurável é ~0,8 A (81,92 mV de faixa no shunt). O robô consome vários ampères, então:
- trocar o shunt por **2 mΩ** (mede até ~40 A); ou
- usar um shunt externo de 50–75 mV para 20 A.

O valor do shunt é um parâmetro em `config.h` e precisa bater com o hardware real. Avise o usuário antes de confiar nas leituras de corrente.
