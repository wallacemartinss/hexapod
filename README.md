# Hexápode aranha

Robô hexápode impresso em 3D, com 18 servos MG996R (3 graus de liberdade por perna), controlado por um app Flutter via Wi-Fi (e, no futuro, 4G).

## Arquitetura

```
App Flutter ──WebSocket (Protobuf)──► Raspberry Pi 3 (hexd, MediaMTX)
                                          │ USB (COBS + CRC16 + nanopb)
                                          ▼
                                     ESP32-S3 (tempo real, failsafe)
                                          │ I2C
                              ┌───────────┴───────────┐
                        2x PCA9685 (servos)     Sensores (BNO085, VL53L0X,
                                                 BME280, INA226)
```

- **ESP32-S3:** movimento a 50 Hz (marcha, IK, limites), sensores e **failsafe**, que não pode ser desligado remotamente.
- **Raspberry Pi:** ponte entre o app e o ESP32 (`hexd`), vídeo e áudio (MediaMTX), rede (Wi-Fi + Tailscale).
- **App:** pilotagem, telemetria e vídeo.

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `proto/` | Contrato Protobuf único (buf) |
| `firmware/` | Firmware do ESP32-S3 (PlatformIO, Arduino + FreeRTOS) |
| `pi/hexd/` | Serviço Go que roda no Pi |
| `pi/hexsim/` | Simulador do ESP32 (mesmo protocolo) para testar sem hardware |
| `pi/provision/` | Ansible para preparar o Pi |
| `pi/mediamtx/`, `pi/systemd/` | Configuração do streaming e dos serviços |
| `pi/deploy/` | Script de deploy com verificação e rollback |
| `app/` | App Flutter |
| `cad/` | STLs e diagramas |

## Segurança

O firmware inicia com os **servos desligados** (OE das PCA9685 em alto). Nenhum teste com hardware real acontece sem a lista do que vai ocorrer fisicamente e confirmação explícita. Detalhes em [`CLAUDE.md`](CLAUDE.md), seções 2 e 6.

## Estado

Em desenvolvimento — o hardware ainda está chegando. Prioridade: simulador, testes nativos e mocks.
