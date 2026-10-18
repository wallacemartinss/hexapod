# App de pilotagem

App Flutter (Android) para pilotar o hexápode pelo `hexd` (WebSocket) e ver a câmera (MediaMTX). Estilo app de drone: paisagem, tela cheia, vídeo de fundo e controles translúcidos.

## Rodar

```bash
cd app
make help        # lista os comandos
make gen         # gera lib/gen a partir de proto/ (dart pub global activate protoc_plugin)
make run         # no PC (Linux), contra o hexsim/hexd local ou o robô
make install     # compila o APK, instala no celular pelo cabo USB e abre o app
make crash       # mostra o último crash do app no celular
```

No celular: **Depuração USB** ligada e cabo de dados. Alguns aparelhos (Redmi/HyperOS) só aparecem para o `adb` uns 30 s depois e bloqueiam APK baixado pelo navegador: use o `make install`.

Para testar sem o robô: `hexsim` + `hexd -serial tcp://127.0.0.1:7777` (ver `pi/`) e, nos ajustes do app, endereço `127.0.0.1`.

## Testes

```bash
flutter analyze
flutter test                                   # unidade + integração com hexd/hexsim reais (precisa de Go)
flutter test --update-goldens test/pilot_screen_golden_test.dart   # capturas em test/goldens/
```

## Como funciona

| Camada | Arquivo | Papel |
|---|---|---|
| Intenção do piloto | `core/control/control_state.dart` | Sticks, modo, altura, gesto, PARAR. Independe da entrada (tela ou controle PS5) |
| Mapeamento | `core/control/command_mapper.dart` | Zona morta, curva expo, eixos → `Command` |
| Envio | `core/providers.dart` (`commandLoopProvider`) | `Command` a **20 Hz sempre**, inclusive parado (homem-morto) |
| Conexão | `core/link/robot_link.dart` | WebSocket com reconexão automática |
| Tela | `features/pilot/` | Joysticks flutuantes, PARAR, barra de modos, estado, radar |

## Regras de usabilidade e segurança

- **PARAR** sempre visível, um toque, sem confirmação; fica travado até um LEVANTAR.
- **LEVANTAR exige segurar** (0,7 s): nada faz o robô se levantar sozinho por um toque acidental. Pose, Andar e Patas só ficam disponíveis com o robô em pé.
- Joysticks ficam **cinza e inertes** quando o robô não pode se mover; trocar de modo zera os sticks.
- Todo estado do failsafe vira uma frase com **o que aconteceu e o que fazer** (ex.: "Segure LEVANTAR para retomar").
- Sem conexão: aviso central, reconexão automática e acesso aos ajustes.
- **Régua de altura e barra de modos somem** depois de 5 s pilotando; um toque rápido na tela traz de volta (arrastar um joystick não). Ficam fixas com o robô sentado, depois de alertas ou sem conexão. PARAR, radar e barra de estado nunca somem. Desligável em Ajustes.

## Controles

| Modo | Stick esquerdo | Stick direito |
|---|---|---|
| Pose | inclina para os lados e frente/trás | gira o corpo no lugar |
| Andar | frente, trás e lados | gira e inclina a "câmera" (olhar) |
| Patas | pata dianteira esquerda (cima levanta, fora estica) | pata dianteira direita |

Opção **Canhoto** troca os sticks de lado. Gestos no modo Patas: Acenar, Guarda, Golpe.

## Controle PS5 (DualSense)

Pareie no Bluetooth do celular. O controle escreve no **mesmo estado** que os joysticks da tela, com as mesmas regras de segurança.

| Controle | Ação |
|---|---|
| Sticks | Iguais aos da tela |
| **Bolinha** | **PARAR** |
| D-pad cima (segurar) | Levantar (vibra a cada quarto do "carregamento" e confirma no fim) |
| D-pad baixo | Sentar |
| Xis / Quadrado / Triângulo | Andar / Pose / Patas (só com o robô em pé) |
| L2 / R2 | Abaixa / sobe o corpo, proporcional à pressão |
| **L1 segurado no modo Pose** | **Inclinar o controle inclina o robô** (o jeito que você segura ao apertar vira o "nível") |
| L1 / R1 / R3 no modo Patas | Guarda / Acenar / Golpe |

**Barra de LED** (Android 12+): verde andando, ciano pose, roxo patas, azul relaxado/sentado, âmbar alerta, vermelho perigo ou PARADO, cinza sem conexão.

**Vibração** (motores do controle): tranco no PARAR, dois pulsos quando o failsafe age, pulso longo se o sinal cai, zumbido crescente com obstáculo à frente enquanto anda, toque curto nos gestos.

Se o Bluetooth cair, os sticks voltam a zero na hora. Recursos que o celular não expõe (LED, sensores ou vibração do controle dependem do kernel do aparelho) são ignorados sem erro. Gatilhos adaptativos e vibração "HD" não são acessíveis a apps no Android.
