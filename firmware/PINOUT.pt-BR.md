# Pinagem do controlador

[English](PINOUT.md) · **Português**

Mapa de cada pino do ESP32 e sua função, para as duas placas. A fonte para o código é [`include/pins.h`](include/pins.h): **mudou aqui, mude lá** (e vice-versa).

| Placa | Uso | Ambiente PlatformIO |
|---|---|---|
| ESP32-S3 SuperMini | Robô final | `esp32s3` |
| ESP32 DevKit 38 pinos (ESP-WROOM-32) | Testes de bancada, temporária | `esp32dev` |

## Sinais (iguais nas duas placas)

| Sinal | Direção | Liga em | Função |
|---|---|---|---|
| `SERVO_SDA` / `SERVO_SCL` | I2C 0, 400 kHz | SDA/SCL das **duas** PCA9685 | Barramento dos servos |
| `SENSOR_SDA` / `SENSOR_SCL` | I2C 1 | SDA/SCL de VL53L0X ×4, BNO085, BME280, INA226 | Barramento dos sensores |
| `PCA_OE` | Saída | OE das **duas** PCA9685 (em paralelo) | **Corte de emergência.** Alto = todos os servos sem pulso |
| `XSHUT0..3` | Saída | XSHUT de cada VL53L0X | Liga um sensor por vez no boot para trocar o endereço 0x29 → 0x30–0x33 |
| `IMU_INT` | Entrada | INT do BNO085 | Avisa que há leitura nova (ativo em baixo) |
| `IMU_RST` | Saída | RST do BNO085 | Reinicia a IMU se ela travar (ativo em baixo) |
| `LED_DATA` | Saída | DIN do primeiro WS2812 | Os dois faróis, um de cada lado da câmera |
| `EYES_TX` / `EYES_RX` | — | **Livres** | Eram do ESP32 dos olhos, que saiu do projeto: o olho fica no Pi |
| USB | — | Raspberry Pi | Protocolo (COBS + CRC16 + nanopb) e gravação do firmware |

## ESP32-S3 SuperMini (robô final)

| GPIO | Sinal | Observação |
|---|---|---|
| 1 | `PCA_OE` | Precisa de *pull-up* externo (ver abaixo) |
| 2 | `LED_DATA` | |
| 4 | `SERVO_SDA` | |
| 5 | `SERVO_SCL` | |
| 6 | `SENSOR_SDA` | |
| 7 | `SENSOR_SCL` | |
| 8 | `XSHUT0` | VL53L0X **frente** → 0x30 |
| 9 | `XSHUT1` | VL53L0X **direita** → 0x31 |
| 14 | `XSHUT2` | VL53L0X **trás** → 0x32 (saiu do GPIO10 para liberar um pino do ADC1) |
| 11 | `XSHUT3` | VL53L0X **esquerda** → 0x33 |
| 12 | `IMU_INT` | |
| 13 | `IMU_RST` | |
| 10 | `GAS_AO` | MQ-2, saída analógica, **pelo divisor 10 kΩ/15 kΩ** (ver abaixo). ADC1 |
| 43 | (livre) | Era `EYES_TX`. Recebe o log da ROM no boot: serve para uma UART de depuração |
| 44 | (livre) | Era `EYES_RX` |
| 48 | LED RGB da placa | Estado do firmware |
| 0 | — | Botão BOOT, não usar |
| 3 | — | *Strapping*, livre mas evitado |
| 19, 20 | — | USB nativa, **proibidos** |

> **A conferir quando a placa chegar:** se o SuperMini comprado expõe GPIO1–13, 43 e 44 nesses pads. Os 14 sinais usam todos os GPIOs seguros disponíveis; não sobra pino livre.

## ESP32 DevKit 38 pinos, ESP-WROOM-32 (bancada)

| GPIO | Sinal | Observação |
|---|---|---|
| 27 | `PCA_OE` | Precisa de *pull-up* externo (ver abaixo) |
| 23 | `LED_DATA` | |
| 21 | `SERVO_SDA` | I2C padrão da placa |
| 22 | `SERVO_SCL` | |
| 32 | `SENSOR_SDA` | |
| 33 | `SENSOR_SCL` | |
| 18 | `XSHUT0` | VL53L0X **frente** → 0x30 |
| 19 | `XSHUT1` | VL53L0X **direita** → 0x31 |
| 13 | `XSHUT2` | VL53L0X **trás** → 0x32 |
| 14 | `XSHUT3` | VL53L0X **esquerda** → 0x33. Oscila no boot (inofensivo: só reinicia o sensor) |
| 34 | `IMU_INT` | Pino só de entrada, ideal para INT |
| 25 | `IMU_RST` | |
| 35 | `GAS_AO` | MQ-2, saída analógica, **pelo divisor 10 kΩ/15 kΩ**. ADC1, só entrada |
| 17 | (livre) | Era `EYES_TX` (UART2) |
| 16 | (livre) | Era `EYES_RX` (UART2) |
| 1, 3 | USB (CP2102) | UART0 = link com o Pi. **Não usar** |
| 6–11 | — | Memória flash, **proibidos** (SD0–SD3, CMD, CLK na placa) |
| 0, 2, 5, 12, 15 | — | *Strapping*: afetam o boot, evitados |
| 4, 26, 36 (VP), 39 (VN) | livres | 36/39 são só entrada |

## Raspberry Pi: GPS, o olho e a tela OLED

Eles ficam no Pi, não no ESP32: o quadro serial do ESP32 está cheio (250 de 254 bytes), o GPS não é tempo real, e só o Pi sabe IP, rede e se o app está conectado (a tela pode mostrar o QR de pareamento). Ativados pelo Ansible (`enable_i2c`, `enable_gps_uart`).

| Módulo | Pino do módulo | Pino físico do Pi | Observação |
|---|---|---|---|
| OLED SSD1306 0,96" (I2C, 0x3C) | VCC | 1 (3,3 V) | |
| | GND | 9 | |
| | SDA | 3 (GPIO2) | `/dev/i2c-1` |
| | SCL | 5 (GPIO3) | |
| Olho ST7789 1,54" (SPI, 240×240) | VCC | 1 (3,3 V) | No lugar da OLED (o olho a substitui) |
| | GND | 20 | |
| | SCL / SCK | 23 (GPIO11, SPI0 SCLK) | |
| | SDA / MOSI | 19 (GPIO10, SPI0 MOSI) | |
| | CS | 24 (GPIO8, SPI0 CE0) | Muitas placas de 1,54" não têm CS: aí, SPI modo 3 |
| | DC | 22 (GPIO25) | Dado / comando |
| | RES | 18 (GPIO24) | Reset |
| | BLK | 12 (GPIO18) | Luz de fundo (PWM: brilho) |
| GPS GY-NEO6MV2 (UART, 9600) | VCC | 17 (3,3 V) | O módulo aceita 3,3–5 V |
| | GND | 14 | |
| | TX | 10 (GPIO15, RX do Pi) | `/dev/serial0` |
| | RX | 8 (GPIO14, TX do Pi) | Opcional: só para configurar o GPS |

Os pinos 2 e 4 (5 V) e 6 (GND) alimentam o Pi a partir do Mini560 no robô. **Ligar e desligar módulos com o Pi desligado.**

- **GPS:** só pega posição (*fix*) com o céu à vista. O primeiro *fix* pode levar minutos; a bateria do módulo guarda o almanaque para os próximos.
- **Validar:** `ssh hexasys@hexapod.local 'bash -s' < pi/provision/check.sh` (seções OLED e GPS).

## MQ-2 (gás e fumaça)

O módulo é alimentado em **5 V** (Mini560) e o aquecedor consome **~150 mA**. A saída analógica `AO` vai de 0 a **5 V**, mas o pino do ESP32 aguenta no máximo 3,3 V. Por isso, **nunca ligue `AO` direto**:

```
AO ──[10 kΩ]──┬── GAS_AO (GPIO10 no S3, GPIO35 na bancada)
              │
           [15 kΩ]
              │
             GND
```

Com 5 V em `AO`, o pino recebe 3,0 V. A saída digital `DO` (comparador do módulo, também em 5 V) não é usada: o alarme é feito no firmware, comparando com o ar limpo.

- **Aquecimento:** alguns minutos a cada partida (o firmware ignora o alarme nos 3 primeiros) e **24–48 h** ligado na primeira vez, para o sensor estabilizar.
- **Leitura relativa:** o nível é a porcentagem da escala do ADC, não ppm. O alarme dispara quando o nível sobe bem acima da linha de base do ar limpo (`config.h`, bloco MQ-2).
- Enquanto `config::kGasSensorFitted` for `false`, o firmware nem lê o pino e informa `FAULT_GAS_SENSOR`.

## Servos: canal de cada junta

PCA9685 nº 1 (**0x40**) = pernas da **esquerda**; nº 2 (**0x41**) = pernas da **direita**. As duas placas usam o mesmo layout: **um bloco de 4 conectores por perna**, deixando o 4º livre.

```
Vista de cima          PCA 0x40 (esquerda)       PCA 0x41 (direita)
     FRENTE            canal  perna  junta       canal  perna  junta
  0 \      / 3          0     0      coxa         0     3      coxa
     \____/             1     0      fêmur        1     3      fêmur
  1 --|  |-- 4          2     0      tíbia        2     3      tíbia
     /|__|\             4     1      coxa         4     4      coxa
  2 /      \ 5          5     1      fêmur        5     4      fêmur
                        6     1      tíbia        6     4      tíbia
                        8     2      coxa         8     5      coxa
                        9     2      fêmur        9     5      fêmur
                       10     2      tíbia       10     5      tíbia
```

Canais livres: 3, 7, 11–15 em cada placa. Inversão de sentido, offset e limites de cada servo **não** ficam aqui: são calibrados e gravados na NVS.

## Endereços I2C

| Barramento | Dispositivo | Endereço |
|---|---|---|
| I2C 0 (servos) | PCA9685 esquerda | 0x40 (jumpers de fábrica) |
| I2C 0 (servos) | PCA9685 direita | **0x41**: soldar o jumper **A0** |
| I2C 1 (sensores) | VL53L0X frente/direita/trás/esquerda | 0x30/0x31/0x32/0x33 (trocados no boot; de fábrica todos 0x29) |
| I2C 1 | BNO085 | 0x4A |
| I2C 1 | BME280 | 0x76 |
| I2C 1 | INA226 | 0x40 (não conflita com a PCA: outro barramento) |

## Quando um sensor chegar

O firmware acha cada sensor I2C pelo ID no boot e tenta de novo, a cada 5 s, os que faltam. Por isso dá para ligar um de cada vez, sem nada para ativar no código. Enquanto o chip não responde, a falha dele fica em `fault_flags` e o app mostra como não instalado. Confira com o robô sentado e **sem energia nos servos**:

| Sensor | Funciona quando | Ajustar antes de confiar |
|---|---|---|
| BME280 | Temperatura, umidade e pressão aparecem no app (~1 s) | Nada |
| INA226 | A tensão da bateria bate com o multímetro | **A corrente:** com o shunt de fábrica (0,1 Ω) ela satura em ~0,8 A. Coloque o de 2 mΩ (`kShuntOhm`), compare com um alicate amperímetro e então mude `kShuntConfirmed = true`; até lá o alarme de sobrecorrente ignora a corrente |
| VL53L0X (cada um) | A barra dele no radar acompanha a mão (0,03–2 m) | XSHUT no pino certo: frente, direita, trás, esquerda. Fio trocado bloqueia a direção errada |
| BNO085 | Roll e pitch acompanham o corpo; inclinando mais de 35° aparece `TIPPED` | Com o robô nivelado, roll e pitch devem ler ~0°: ajuste `kImuRollOffsetDeg`/`kImuPitchOffsetDeg`. Abaixe o lado direito: o roll tem de ficar **positivo**; abaixe o nariz: o pitch **positivo**. Se não, a placa está montada girada e os eixos precisam ser remapeados |

## Cuidados de ligação

### OE das PCA9685: *pull-up* obrigatório

O padrão seguro do projeto é **servos desligados**. Mas, nas placas compatíveis com a Adafruit (como a HW-170), o OE vem com um resistor para GND, o que **liga** as saídas enquanto o ESP32 está em reset e o pino flutua.

- Ligar um **resistor de 1 kΩ entre `PCA_OE` e 3,3 V**.
- Com as duas placas em paralelo (2 × 10 kΩ para GND = 5 kΩ), o OE fica em ~2,75 V, acima do mínimo de nível alto da PCA9685 (0,7 × 3,3 V = 2,31 V). Um resistor maior (4,7 kΩ ou 10 kΩ) **não** garante o nível alto.
- **Conferir com multímetro**, com o ESP32 desconectado: o OE deve medir ≥ 2,5 V.

Consequência: depois de um reset do ESP32, os servos ficam **sem torque** até o firmware ler as PCA9685 e reativar o OE. Isso segue a regra de segurança nº 1; o robô deve estar apoiado ou sentado.

### Alimentação

| Rede | Origem | Destino |
|---|---|---|
| 6,0 V (servos) | Step-down de 20 A | Borne **V+** das duas PCA9685 (nunca no VCC) |
| 5 V (lógica) | Mini560 | Pi (pinos 2/6 do GPIO), 5 V do ESP32, WS2812 |
| 3,3 V | Regulador do ESP32 | **VCC** das PCA9685 e de todos os sensores |
| GND | **Comum a tudo** | Bateria, step-down, Mini560, ESP32, Pi, PCA9685, sensores |

- O VCC das PCA9685 em **3,3 V** deixa o I2C no mesmo nível do ESP32, sem conversor.
- Cada placa de sensor traz seus próprios *pull-ups* no I2C, e no barramento de sensores são 7 em paralelo. Com 10 kΩ em cada, o total fica em ~1,4 kΩ, dentro do limite (mínimo de ~1 kΩ a 3,3 V). Placas com 4,7 kΩ podem passar do limite: **com tudo desligado, medir a resistência entre SDA e 3,3 V**. Se der menos de 1 kΩ, remover os *pull-ups* de algumas placas.
- O 3,3 V do DevKit (AMS1117) aguenta ~600 mA no total: suficiente para os sensores, mas **nunca** alimentar servos ou LEDs por ele.

### WS2812

- Alimentação em 5 V; dado em 3,3 V funciona na maioria das fitas, mas fora da especificação. Se o primeiro LED piscar errado, usar um conversor de nível (74AHCT125) ou um resistor de 330 Ω em série no dado.
- Decisão WS2812 vs. LEDs de 1 W ainda pendente.

### INA226

O shunt de fábrica (0,1 Ω) mede só até ~0,8 A. Ver o aviso do shunt na [lista de peças](../README.pt-BR.md#lista-de-peças) antes de confiar na corrente.
