# Instalação maker

[English](maker-install.md) · **Português**

Montar o software do robô você mesmo, do Raspberry Pi OS de fábrica até o robô pilotando, com cada passo na sua mão. Se você só quer que funcione, a imagem pronta é mais rápida: [`instalar.md`](instalar.md). Os dois caminhos chegam ao mesmo lugar, e dá para trocar de um para o outro quando quiser.

## Do que você precisa

**No PC (Linux ou macOS; Windows pelo WSL)**

| Ferramenta | Para quê | Conferir |
|---|---|---|
| `git` | o código | `git --version` |
| Go 1.25+ | o `hexd` (serviço do Pi) | `go version` |
| PlatformIO Core | o firmware do ESP32 | `pio --version` |
| `buf` + `protoc-gen-go` + nanopb | código gerado do protocolo | `buf --version` |
| Ansible | preparar o Pi | `ansible --version` |
| Raspberry Pi Imager | o cartão | |
| Flutter 3.41+ (opcional) | compilar o app você mesmo | `flutter --version` |

As ferramentas do protocolo: `go install github.com/bufbuild/buf/cmd/buf@v1.74.0`, `go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12` e `pip install nanopb==0.4.9.1`, com o `~/go/bin` no `PATH`.

**Hardware:** o robô da [lista de peças](../README.pt-BR.md#lista-de-peças), um cartão microSD (16 GB ou mais) e **energia de verdade**: subtensão derruba o Wi-Fi do Pi. Confira quando quiser no app (Dados → Raspberry Pi) ou com `vcgencmd get_throttled` (tem que dar `0x0`).

```bash
git clone https://github.com/wallacemartinss/hexapod.git
cd hexapod
```

## 1. Gravar o Raspberry Pi OS

No Raspberry Pi Imager: **Raspberry Pi OS Lite (64-bit)** e depois *Editar configurações*:

- hostname `hexapod`;
- seu usuário e senha;
- **SSH com a sua chave pública** (*Serviços → Permitir apenas autenticação por chave pública*);
- seu Wi-Fi (o Pi 3 só enxerga 2,4 GHz) e o país.

Ligue o Pi e confira o acesso: `ssh <você>@hexapod.local`. Sua rede não tem mDNS? Use o IP no lugar do nome em tudo abaixo.

## 2. Preparar o Pi com Ansible

O playbook instala e configura tudo: câmera, MediaMTX (vídeo e áudio), o serviço `hexd` e o usuário dele, a regra udev do ESP32, I2C (tela), UART (GPS), Tailscale, o watchdog de hardware e a economia de energia. Pode rodar de novo à vontade: ele só muda o que estiver diferente.

```bash
cd pi/provision
ansible-playbook site.yml -e ansible_user=<você> --check --diff   # simulação: mostra o que mudaria
ansible-playbook site.yml -e ansible_user=<você>                  # aplica (reinicia quando muda algo do boot)
ssh <você>@hexapod.local 'bash -s' < check.sh                     # validação
```

O `check.sh` confere câmera, microfone, energia, ESP32, OLED (0x3C), GPS e Tailscale. Resolva o que ele apontar antes de seguir. Detalhes e opções: [`pi/provision/README.md`](../pi/provision/README.md).

## 3. Gerar e instalar o software

Um pacote leva o `hexd` e o firmware do ESP32, compilado para a sua placa (`esp32s3` no robô, `esp32dev` para um ESP32 clássico na bancada):

```bash
BOARD=esp32s3 pi/deploy/package.sh            # → dist/hexapod-<versão>.tar.gz
scp dist/hexapod-<versão>.tar.gz <você>@hexapod.local:/tmp/
ssh <você>@hexapod.local
cd /tmp && tar -xzf hexapod-<versão>.tar.gz --wildcards '*/deploy.sh' --strip-components=1
sudo bash ./deploy.sh /tmp/hexapod-<versão>.tar.gz --bootstrap
```

O `--bootstrap` é só para essa **primeira** instalação (ainda não há `hexd` respondendo). Daí em diante, sem ele: o deploy se recusa a rodar se o robô não estiver sentado ou relaxado, grava o ESP32, reinicia o `hexd`, confere se as duas versões respondem em até 10 s e, se não, **volta a anterior**. Guarda as últimas 5 versões.

Conferir: `curl http://hexapod.local:8080/version` mostra a mesma versão no `hexd` e no firmware, e a telinha mostra as páginas de estado do robô.

## 4. Instalar o app e parear

- **App:** o APK da página de Releases, ou compile: `cd app && make install` (celular no USB, depuração USB ligada).
- **Pareamento:** com nenhum app conectado, a tela do robô mostra um QR e um código de 5: no app, **Parear um robô** e aponte a câmera. Sem a tela, pegue a chave longa pelo terminal:

```bash
sudo -u hexapod /opt/hexapod/current/bin/hexd -pairing   # mostra a chave e um QR (HXP1 <id> <chave>)
```

Digite `HXP1 <id> <chave>` na tela de pareamento no lugar do código curto. As ferramentas de linha de comando usam a mesma chave (`-token` ou `HEXAPOD_TOKEN`).

## 5. Acesso remoto (opcional)

Pilote de qualquer lugar pelo Tailscale: configure pelo app ([passo a passo](acesso-remoto.md)) ou pelo terminal:

```bash
ssh <você>@hexapod.local 'sudo tailscale up --hostname=hexapod'   # mostra um link de login
```

## 6. Proteger o cartão (opcional)

Com a raiz somente leitura, tirar a energia nunca corrompe o cartão; o `/opt/hexapod` (versões, ajustes, chave de pareamento) vai para uma partição própria. Precisa do cartão no PC uma vez, para dividir: [`pi/provision/README.md`](../pi/provision/README.md#somente-leitura-proteger-o-cartão).

## Mantendo atualizado

- **Versão nova:** repita o passo 3 sem `--bootstrap`, com o robô sentado.
- **Ajustes do Pi:** atualize o código e rode o playbook de novo.
- **Só o firmware, na mão:** `cd firmware && pio run -e esp32s3 -t upload` com o ESP32 no USB do PC.

## Olhando por dentro

| O quê | Onde |
|---|---|
| Log do `hexd` | `journalctl -u hexd -f` |
| Métricas (Prometheus) | `http://hexapod.local:8080/metrics` |
| Saúde, versão | `/health`, `/version`, `/status` |
| Vídeo no navegador | `http://hexapod.local:8889/cam` |
| Telemetria ao vivo, do PC | `cd pi && go run ./cmd/hexctl -url ws://hexapod.local:8080/ws -token <chave> watch` |
| Sem robô nenhum | o `hexsim` simula o ESP32: ver [`app/README.md`](../app/README.md) |

## Quando algo dá errado

| O que acontece | Causa provável | O que fazer |
|---|---|---|
| O `check.sh` avisa de throttling | Fonte fraca | Fonte de 5,1 V / 2,5 A na bancada (3 A no Pi 4); Mini560 em 5,1 V no robô |
| Não existe `/dev/hexapod-esp32` | Cabo só de carga, ou outro ESP32 | Cabo de dados; o `lsusb` tem que mostrar `303a:1001` (S3) ou `10c4:ea60` (placa de bancada) |
| Deploy: `robot is NORMAL: sit it down first` | Robô em pé | Sente pelo app e rode de novo |
| Deploy: `verification failed ... rolling back` | A versão nova não subiu em 10 s | Ele já voltou a anterior; leia `journalctl -u hexd -b` |
| O app diz que o robô recusou a chave | Pareado antes de reinstalar (chave nova) | Parear de novo |
| OLED ausente no `check.sh` | Fiação, ou I2C desligado | SDA → pino 3, SCL → pino 5; `i2cdetect -r -y 1` tem que mostrar `3c` |
