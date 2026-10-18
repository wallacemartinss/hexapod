# Provisionamento do Raspberry Pi

Playbook Ansible idempotente que prepara o Pi do hexápode (Fase 1.2) e um script de validação (Fase 1.3). Pode rodar quantas vezes quiser: só muda o que estiver diferente.

## Pré-requisitos

- Pi gravado conforme o runbook do cartão SD (usuário `wallace`, acesso por chave SSH).
- `ssh wallace@hexapod.local` funcionando a partir do PC.
- Ansible no PC (`ansible --version`).

## Uso

```bash
cd pi/provision
ansible-playbook site.yml --check --diff   # simulação, não altera nada
ansible-playbook site.yml                  # aplica
ansible-playbook site.yml --tags mediamtx  # só uma parte
ansible-playbook site.yml -e ansible_host=10.0.0.86   # sem mDNS
```

**Tailscale:** a auth key nunca entra no repositório. Para fazer login pelo playbook:

```bash
TS_AUTHKEY=tskey-... ansible-playbook site.yml --tags tailscale -e tailscale_authkey="$TS_AUTHKEY"
```

Ou, manualmente no Pi: `sudo tailscale up --hostname=hexapod`.

**Validação** (roda no Pi):

```bash
ssh wallace@hexapod.local 'bash -s' < check.sh
```

## O que o playbook faz

| Parte | Tag | Detalhe |
|---|---|---|
| Pacotes | `base` | `apt dist-upgrade` (desligável com `apt_upgrade: false`), `rpicam-apps`, `alsa-utils`, `ffmpeg`, `avahi-daemon`, `git`, `rsync`; `esptool` do PyPI com versão fixa em `/opt/esptool` (o pacote do Debian não traz o *stub flasher*) |
| Boot | `boot` | Câmera (`camera_auto_detect=1`, ou `dtoverlay=ov5647` com `camera_force_ov5647: true`) e economia de energia. **Reinicia o Pi** se mudar algo (`provision_reboot`) |
| Layout | `layout` | Usuário de serviço `hexapod` (grupos `dialout`, `video`, `audio`), `/opt/hexapod/{releases,shared/{config,logs,firmware}}`, `hexd.yaml` (só se não existir) e regra polkit que deixa o `hexapod` **apenas** desligar o Pi (bateria crítica) |
| udev | `udev` | ESP32-S3 `303a:1001` → `/dev/hexapod-esp32`, ignorado pelo ModemManager (para o modem 4G no futuro). **Temporário:** CP2102/CH340 de DevKits clássicos para testes de bancada (`esp32_test_usb_ids`; esvaziar quando o S3 chegar) |
| Tailscale | `tailscale` | Repositório oficial; `tailscale up` só com `tailscale_authkey` |
| MediaMTX | `mediamtx` | Binário arm64 com versão fixa (`mediamtx_version`) e checksum conferido; config em `pi/mediamtx/mediamtx.yml` |
| Serviços | `services` | `hexd`, `mediamtx` e `mic-stream` com `Restart=always`. O `hexd` fica habilitado, mas só sobe depois do primeiro deploy |
| Watchdog | `watchdog` | `RuntimeWatchdogSec=14s`, sobrescrevendo o padrão de 1 min do Raspberry Pi OS (`40-rpi-enable-watchdog.conf`) |

### Economia de energia

Tudo controlado em `group_vars/all.yml`; cada item exige reboot.

| Opção | Efeito | Por que pode desligar |
|---|---|---|
| `disable_bluetooth` | `dtoverlay=disable-bt` | O robô não usa Bluetooth |
| `disable_onboard_audio` | `dtparam=audio=off` | O microfone é USB e o Pi não tem alto-falante |
| `disable_hdmi` | `video=HDMI-A-1:d` no `cmdline.txt` | Robô sem tela. Para depurar com monitor, ponha `false` e reaplique |

**Não** ativa o sistema de arquivos somente leitura (overlay): isso fica para a Fase 5.

## Pendências de hardware

- `mic_alsa_device`: confirmar o nome com `arecord -L` quando o microfone USB estiver plugado.
- Caminho `mic` separado do `cam`: validar no hardware; se for melhor juntar áudio e vídeo num caminho só, ajustar o `mediamtx.yml`.
