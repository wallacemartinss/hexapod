# Preparação do Raspberry Pi (Ansible)

[English](README.md) · **Português**

Este playbook transforma um Raspberry Pi OS Lite de fábrica no "cérebro" do robô. Ele é **idempotente**: pode rodar quantas vezes quiser, porque só muda o que estiver diferente. É o mesmo playbook que gera a imagem pronta do cartão (`pi/image/build-image.sh`, em modo `image_build`), então o caminho maker e o simples terminam no mesmo sistema.

## O que é o Ansible (para quem nunca usou)

O [Ansible](https://docs.ansible.com) roda **no seu PC** e configura outra máquina **pela rede, via SSH**. No Pi não se instala nada além do que o próprio playbook pede. Em vez de uma lista de comandos para copiar e colar, o playbook descreve **como o Pi deve ficar** ("este pacote instalado", "esta linha no `config.txt`", "este serviço ligado"). O Ansible confere cada item e só mexe no que está diferente. Isso traz três vantagens:

- **Repetível:** um Pi novo fica igual ao anterior, sem esquecer passo.
- **Seguro de rodar de novo:** depois de atualizar o código, rode outra vez; o que já está certo não muda.
- **Legível:** cada passo é um arquivo YAML curto em `tasks/`, com o porquê comentado.

## Pré-requisitos

- Pi gravado com o **Raspberry Pi OS Lite (64-bit)**, com hostname `hexapod`, seu usuário e **chave SSH** (veja o [guia maker](../../docs/instalacao-maker.md#1-gravar-o-raspberry-pi-os)).
- `ssh <você>@hexapod.local` funcionando a partir do PC.
- Ansible no PC: `pipx install ansible-core` ou o pacote da sua distribuição (`ansible --version`).

## Uso

```bash
cd pi/provision
ansible-playbook site.yml -e ansible_user=<você> --check --diff   # simulação: mostra o que mudaria, não altera nada
ansible-playbook site.yml -e ansible_user=<você>                  # aplica (reinicia o Pi se algo do boot mudar)
ansible-playbook site.yml -e ansible_user=<você> --tags mediamtx  # só uma parte (ver as tags abaixo)
ansible-playbook site.yml -e ansible_host=10.0.0.86               # sem mDNS: pelo IP
```

O inventário (`inventory.yml`) aponta para `hexapod.local` com o usuário `wallace`; `-e ansible_user=` e `-e ansible_host=` sobrescrevem.

**Validação** (roda no Pi e confere câmera, microfone, energia, ESP32, tela, GPS e Tailscale):

```bash
ssh <você>@hexapod.local 'bash -s' < check.sh
```

**Tailscale:** a chave de acesso nunca entra no repositório. O mais simples é pelo app (Ajustes → Acesso remoto). Pelo playbook:

```bash
TS_AUTHKEY=tskey-... ansible-playbook site.yml --tags tailscale -e tailscale_authkey="$TS_AUTHKEY"
```

## O que o playbook faz

| Parte | Tag | Detalhe |
|---|---|---|
| Pacotes | `base` | `apt dist-upgrade` (desligável com `apt_upgrade: false`), `rpicam-apps`, `alsa-utils`, `ffmpeg`, `avahi-daemon` (+ anúncio `_hexapod._tcp` para o app achar o robô), `i2c-tools`, `jq`, `polkitd`; `esptool` do PyPI com versão fixa em `/opt/esptool` (o pacote do Debian não traz o *stub flasher*) |
| Boot | `boot` | Câmera (`camera_auto_detect=1`, ou `dtoverlay=ov5647`), **I2C** (tela OLED), **SPI** (olho ST7789), **UART** do GPS sem console serial, país do Wi-Fi (`regdom`) e economia de energia. **Reinicia o Pi** se mudar algo |
| Layout | `layout` | Usuário de serviço `hexapod` (grupos `dialout`, `video`, `audio`, `i2c`, `spi`, `gpio`), `/opt/hexapod/{releases,shared/{config,logs,firmware}}`, `hexd.yaml` (só se não existir) e regras polkit **mínimas**: desligar o Pi (bateria crítica), controlar o Wi-Fi pelo NetworkManager e reaplicar o operador do Tailscale |
| udev | `udev` | ESP32-S3 `303a:1001` → `/dev/hexapod-esp32`, ignorado pelo ModemManager; ao plugar uma placa, dispara a gravação do firmware se ela não tiver o do hexápode. **Temporário:** IDs de DevKits clássicos para a bancada (`esp32_test_usb_ids`) |
| Tailscale | `tailscale` | Repositório oficial; `tailscale up` só com `tailscale_authkey` |
| MediaMTX | `mediamtx` | Binário arm64 com versão fixa (`mediamtx_version`) e checksum conferido; config em `pi/mediamtx/mediamtx.yml` |
| Serviços | `services` | `hexd`, `mediamtx`, `mic-stream`, a tela de boot, a gravação automática do ESP32, o desbloqueio do Wi-Fi e o operador do Tailscale. O `hexd` sobe depois do primeiro deploy |
| Watchdog | `watchdog` | `RuntimeWatchdogSec=14s`: se o sistema travar, o chip reinicia o Pi |
| Somente leitura | `readonly` | Raiz em overlay com o `/opt/hexapod` numa partição própria (ver abaixo); só com `readonly_root: true` |

Todas as opções ficam em [`group_vars/all.yml`](group_vars/all.yml), comentadas.

### Economia de energia

Cada item exige reboot.

| Opção | Efeito | Por que pode desligar |
|---|---|---|
| `disable_bluetooth` | `dtoverlay=disable-bt` | O robô não usa Bluetooth, e isso libera a UART boa para o GPS |
| `disable_onboard_audio` | `dtparam=audio=off` | O microfone é USB e o Pi não tem alto-falante |
| `disable_hdmi` | `video=HDMI-A-1:d` e `HDMI-A-2:d` no `cmdline.txt` | Robô sem monitor (o Pi 4 tem duas saídas). Para depurar com monitor, ponha `false` e reaplique |

## Somente leitura (proteger o cartão)

Com a raiz somente leitura, o sistema roda numa camada em memória (`overlayroot`): desligar o robô de qualquer jeito não corrompe o cartão, e mudanças no sistema somem ao reiniciar. O que precisa persistir fica numa **partição própria**, gravável: o `/opt/hexapod` (versões, configuração, firmware anterior, galeria da câmera, chave de pareamento) e o login do Tailscale.

**Uma vez só, com o cartão no PC** (faça antes uma imagem de backup do cartão):

```bash
lsblk                                              # ache o cartão (ex.: /dev/sdb, partições bootfs e rootfs)
sudo pi/provision/make-data-partition.sh /dev/sdX  # raiz vai para 24 GB, cria "hexdata" com o resto
```

O script confere se é um cartão do Pi (rótulos `bootfs`/`rootfs`, removível, nada montado), mostra o plano e só segue com **SIM**. Nada é apagado: o `/opt/hexapod` antigo fica em `/opt/hexapod.before-data`.

**Depois, com o cartão de volta no Pi:**

```bash
ansible-playbook site.yml --tags readonly -e readonly_root=true   # liga e reinicia
```

**No dia a dia, no Pi:**

| Comando | Para quê |
|---|---|
| `hexapod-readonly status` | Como está agora e no próximo boot |
| `sudo hexapod-readonly off && sudo reboot` | **Antes** de `apt`, Ansible ou qualquer mudança no sistema |
| `sudo hexapod-readonly on && sudo reboot` | Proteger de novo |

- O playbook **recusa rodar** com a raiz somente leitura (as mudanças sumiriam).
- O `deploy.sh` continua funcionando: só escreve em `/opt/hexapod`.
- Não use a opção de overlay do `raspi-config`: ela congela também o `/opt/hexapod` (falta o `recurse=0`).
- Os logs ficam em memória (até 32 MB) e somem ao reiniciar.

## Pendências de hardware

- `mic_alsa_device`: confirmar o nome com `arecord -L` quando o microfone USB estiver plugado.
- `esp32_test_usb_ids`: esvaziar quando o ESP32-S3 chegar.
