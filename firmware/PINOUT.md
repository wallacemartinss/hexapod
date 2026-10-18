# Pinagem do controlador

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
| `LED_DATA` | Saída | DIN do primeiro WS2812 | Fita de LEDs de estado |
| `EYES_TX` / `EYES_RX` | UART | RX/TX do ESP32 dos olhos (cruzado) | Fase futura |
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
| 43 | `EYES_TX` | Também recebe o log da ROM no boot; o protocolo dos olhos precisa ignorar lixo |
| 44 | `EYES_RX` | |
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
| 17 | `EYES_TX` | UART2 |
| 16 | `EYES_RX` | UART2 |
| 1, 3 | USB (CP2102) | UART0 = link com o Pi. **Não usar** |
| 6–11 | — | Memória flash, **proibidos** (SD0–SD3, CMD, CLK na placa) |
| 0, 2, 5, 12, 15 | — | *Strapping*: afetam o boot, evitados |
| 4, 26, 36 (VP), 39 (VN) | livres | 36/39 são só entrada |

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
- Decisão WS2812 vs. LEDs de 1 W ainda pendente (`CLAUDE.md`, seção 7).

### INA226

O shunt de fábrica (0,1 Ω) mede só até ~0,8 A. Ver o `CLAUDE.md`, seção 9, antes de confiar na corrente.
