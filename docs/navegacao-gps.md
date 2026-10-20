# Navegação por GPS

[English](gps-navigation.md) · **Português**

O robô anda sozinho até um ponto do mapa, volta para casa, patrulha uma rota e fica dentro de uma cerca virtual. Tudo pelo app, na tela **Mapa** (ícone de mapa no alto da tela de pilotagem).

> **Estado:** pronto no simulador. No robô de verdade, a condução fica **desligada** (`nav.drive: false` no `hexd.yaml`) até os servos estarem calibrados e o primeiro teste ser feito com a mão no PARAR.

## Como usar

1. Ligue o robô com o **céu à vista**. O GPS leva de alguns segundos a alguns minutos para achar a posição. A **casa** é marcada sozinha onde o robô estava ao ligar (ou pelo botão **Casa aqui**).
2. Levante o robô e coloque no modo **Andar**.
3. Na tela Mapa:
   - toque num ponto e em **Ir até aqui**;
   - ou **Voltar para casa**;
   - ou desenhe uma **Rota** (toque nos pontos em ordem, **Salvar**) e use **Patrulhar** (com **Repetir**, ela recomeça no fim);
   - a **Cerca** é desenhada do mesmo jeito (3 cantos ou mais).
4. **Solte os joysticks:** o robô gira para o ponto e anda. Ele vai devagar (até ~5 cm/s) e para a uns 3 m do ponto, que é o quanto o GPS erra.

## Segurança: igual ao Siga-me

- **O app é o homem-morto.** O robô só anda enquanto o app está conectado e mandando comandos no modo Andar. Sem app, nada anda.
- **Mexer num joystick ou apertar PARAR cancela** a missão na hora.
- **Perdeu a conexão?** O ESP32 para o robô, como sempre. Quando o app volta, aparece **Continuar missão**. Ele nunca volta sozinho.
- **Obstáculo à frente** (sensor de distância da frente): a missão espera. Não há desvio automático.
- **Cerca:** o robô não aceita pontos fora dela. Se for parar do lado de fora (carregado, ou pelo erro do GPS), a missão para e o piloto só consegue girar ou andar **de volta para dentro**.
- **Bateria baixa:** o app sugere voltar para casa.

## Para onde o robô aponta

O robô anda a 8 cm/s, devagar demais para o GPS dizer o rumo sozinho. Por isso entram três fontes:

- a **bússola** do BNO085 (magnetômetro), que sabe onde fica o norte, mas é desviada pelas correntes dos servos;
- o **giroscópio**, que é suave mas não sabe onde fica o norte;
- o **GPS**: a cada 10 m andados em linha reta, o deslocamento medido corrige o erro da bússola.

**Declinação magnética:** o norte da bússola não é o norte do mapa (cerca de -21° em São Paulo). Coloque o valor da sua cidade em `nav.declination` ([magnetic-declination.com](https://www.magnetic-declination.com/)). Se ficar em 0, o GPS corrige andando, mas as primeiras dezenas de metros saem tortas.

## Testar sem robô (simulador)

```bash
cd pi
go build -o bin/hexsim ./hexsim && go build -o bin/hexctl ./cmd/hexctl && (cd hexd && go build -o ../bin/hexd ./cmd/hexd)
bin/hexsim -listen tcp://127.0.0.1:7777 -gps tcp://127.0.0.1:7778 -speed 10 &
# hexd.yaml de desenvolvimento: serial.device tcp://127.0.0.1:7777, gps.device tcp://127.0.0.1:7778,
# nav.drive true, auth.required false (e as partes de hardware desligadas)
bin/hexd -config meu-hexd.yaml &
bin/hexctl -url ws://127.0.0.1:8080/ws goto -23.55032 -46.63310   # ou pelo app: make run
```

O hexsim simula a bússola (com declinação de -21° e ruído) e um GPS com o erro típico do NEO-6M, servido em NMEA. `-speed 10` acelera a caminhada para a demonstração.

## Configuração (`hexd.yaml`, bloco `nav:`)

| Chave | Padrão | |
|---|---|---|
| `enabled` | `true` | missões, casa, cerca e rota (precisa do GPS) |
| `drive` | `false` | o hexd conduz o robô durante a missão. **Só depois de testar** |
| `arrive_m` | 3 | distância que conta como "cheguei", m |
| `max_hdop` | 3 | posições piores que isso são ignoradas |
| `declination` | 0 | graus; verdadeiro = magnético + este valor |
| `max_speed`, `max_turn` | 0,6 | fração da velocidade de andar e de girar |
| `store` | `/opt/hexapod/shared/config/nav.json` | a cerca e a rota ficam salvas aqui |

A cerca só vale perto de onde foi desenhada (até 1 km): levar o robô para outro lugar não o deixa "preso fora".

## Limites conhecidos

- O NEO-6M erra de 2 a 5 m: serve para quintal, praça e campo, não para "ir até a porta".
- Não há desvio de obstáculos: com algo à frente, o robô espera.
- A bússola ainda precisa ser conferida no robô montado (`kImuNorthYawDeg` no `config.h`, longe dos cabos dos servos).
