# Contrato Protobuf (`hexapod.v1`)

Fonte única da verdade da comunicação entre **app ↔ hexd ↔ ESP32**. O código gerado não é versionado: sempre se gera a partir daqui.

## Mensagens

Toda mensagem trafega dentro de um `Envelope` (um `oneof`), tanto na serial quanto no WebSocket. Quem recebe olha qual campo veio preenchido.

| Mensagem | Sentido | Frequência |
|---|---|---|
| `Hello` | hexd → ESP32 e resposta ESP32 → hexd | Ao abrir a serial; usado pelo `deploy.sh` para conferir a versão do firmware |
| `Command` | app → hexd → ESP32 | 20 Hz, **mesmo parado** (homem-morto) |
| `LinkConfig` | hexd → ESP32 | Ao mudar de Wi-Fi para 4G; o ESP32 só aplica com o robô sentado |
| `Telemetry` | ESP32 → hexd → app | 10 Hz |
| `CalibrationCommand` / `CalibrationReport` | app ↔ ESP32 | Sob demanda, um servo por vez, só em `MODE_CALIBRATE` |
| `Event` | ESP32 → app | Modo pet (futuro) |

### Convenções

- **Grandezas de movimento são normalizadas** (`vx`, `vy`, `yaw_rate`, `body_roll/pitch/yaw` em −1..1; `body_height` em 0..1). O ESP32 converte usando os limites do `config.h`, então o app não precisa conhecer as dimensões do robô.
- **Enums com valor 0 = `*_UNSPECIFIED`.** Em `Command`, `MODE_UNSPECIFIED`/`GAIT_UNSPECIFIED` significam "manter o atual".
- **`seq` estritamente crescente:** o ESP32 descarta `Command` com `seq` ≤ o último aceito. `estop = true` vale sempre, qualquer que seja o `seq`.
- **`fault_flags`** é um OU de valores do enum `Fault` (já são máscaras de bit).
- **Unidades no nome do campo** (`_mm`, `_deg`, `_v`, `_a`, `_us`, `_ms`, `_c`, `_pct`, `_hpa`).
- **Versão do protocolo:** `PROTOCOL_VERSION = 1`, enviada no `Hello.protocol_version`. Incrementar em qualquer mudança incompatível; `buf breaking` acusa essas mudanças.

## Transporte na serial (USB, ESP32 ↔ Pi)

```
quadro na linha = COBS( payload ‖ CRC16 ) ‖ 0x00
payload         = Envelope codificado (nanopb / protobuf)
```

| Item | Definição |
|---|---|
| Delimitador | `0x00` no fim de cada quadro |
| CRC | **CRC-16/CCITT-FALSE**: polinômio `0x1021`, inicial `0xFFFF`, sem reflexão, XOR final `0x0000`. Valor de verificação: `"123456789"` → `0x29B1` |
| Ordem do CRC | 2 bytes **little-endian**, logo após o payload, calculado só sobre o payload |
| Tamanho máximo | `Envelope` ≤ 249 bytes (`hexapod_v1_Envelope_size`) → quadro ≤ 253 bytes com CRC, COBS e delimitador |
| Quadro inválido | CRC errado, COBS malformado, maior que o máximo ou protobuf que não decodifica: **descartado em silêncio** e contado em métrica |

No WebSocket (app ↔ hexd), cada mensagem binária é um `Envelope` puro: o WebSocket já delimita e verifica a integridade.

## Gerar o código

Requer `buf`, `protoc-gen-go` (`go install`) e `protoc-gen-nanopb` (`pipx install nanopb`) no `PATH`.

```bash
cd proto
buf lint
buf generate        # tudo: Go, C (nanopb) e Dart
buf generate --template buf.gen.firmware.yaml   # só nanopb (o build do firmware faz isso sozinho)
buf generate --template buf.gen.pi.yaml         # só Go
buf generate --template buf.gen.app.yaml        # só Dart (dart pub global activate protoc_plugin)
buf breaking --against '../.git#branch=main,subdir=proto'   # antes de mudar algo
```

| Saída | Onde | Observação |
|---|---|---|
| Go | `pi/hexd/gen/hexapod/v1` | Pacote `github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1` |
| C (nanopb) | `firmware/lib/proto/hexapod/v1` | Sem alocação dinâmica: limites nos `.options` |
| Dart | `app/lib/gen` | `protoc_plugin` (pub global) |

## Limites do nanopb (`*.options`)

| Campo | Limite |
|---|---|
| `Hello.firmware_version`, `Hello.hexd_version` | 31 caracteres |
| `Hello.git_hash` | 40 caracteres (hash SHA-1 completo) |
| `Telemetry.distances_mm` | exatamente 4 (`fixed_count`) |
| `Telemetry.joint_angles_deg` | exatamente 18 (`fixed_count`), ordem perna-a-perna: coxa, fêmur, tíbia |

Mudou um limite? Rode `buf generate` e confira que `hexapod_v1_Envelope_size` continua ≤ 252 (payload + CRC ≤ 254 bytes), para o quadro caber num único bloco COBS.
