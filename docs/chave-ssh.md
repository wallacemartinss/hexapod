# Chave SSH: entrando no robô pelo PC

[English](ssh-key.md) · **Português**

Os makers acessam o Raspberry Pi do robô por **SSH**: um terminal no Pi, a partir do seu PC, pela rede. O Ansible e o deploy também usam. Este guia cria a sua **chave SSH** e coloca no robô, passo a passo. É feito uma vez por PC.

> Só para o caminho maker. O caminho simples (imagem pronta e o app) não precisa de nada disto.

## O que é a chave, e por que não senha

A chave SSH é um par de arquivos:

- **chave privada** (`id_ed25519`): fica no seu PC e **nunca** é compartilhada. É a sua identidade.
- **chave pública** (`id_ed25519.pub`): vai para o robô. É a "fechadura" que só a sua chave privada abre.

Com chave, ninguém entra chutando senha, e você entra sem digitar senha (ou com uma frase secreta que só destrava a chave no seu próprio PC).

## 1. Criar a chave

### Linux e macOS

Abra um terminal:

```bash
ssh-keygen -t ed25519 -C "hexasys"
```

- **Arquivo:** aperte Enter para usar o padrão (`~/.ssh/id_ed25519`). Se disser que o arquivo já existe, você já tem uma chave: responda `n` e vá para o passo 2.
- **Frase secreta (passphrase):** recomendada (protege a chave se alguém copiar os arquivos do seu PC). Pode deixar em branco.

### Windows 10 / 11

Abra o **PowerShell** (o OpenSSH já vem no Windows) e rode o mesmo comando:

```powershell
ssh-keygen -t ed25519 -C "hexasys"
```

A chave vai para `C:\Users\<você>\.ssh\id_ed25519`.

### Ver a sua chave pública

```bash
cat ~/.ssh/id_ed25519.pub          # Linux, macOS
type $env:USERPROFILE\.ssh\id_ed25519.pub   # Windows PowerShell
```

É uma linha que começa com `ssh-ed25519 AAAA...` e termina com `hexasys`. É isso que você copia. **Nunca copie o arquivo sem `.pub`.**

## 2. Colocar no robô ao gravar o cartão

No **Raspberry Pi Imager**, escolha **Raspberry Pi OS Lite (64-bit)** e, quando ele oferecer para **personalizar** o sistema:

1. **Hostname:** `hexapod`.
2. **Usuário:** `hexasys`, com uma senha (usada no `sudo`).
3. **Wi-Fi** e país, se quiser na sua rede (o Pi 3 só enxerga 2,4 GHz).
4. **SSH / acesso remoto:** ative e escolha **somente autenticação por chave pública**. Cole a sua chave pública (a linha `ssh-ed25519 ...`). As versões recentes do Imager leem a chave do seu PC sozinhas.

Grave o cartão, coloque no Pi, ligue e espere um minuto.

## 3. Primeiro acesso

```bash
ssh hexasys@hexapod.local
```

Na primeira vez, o SSH mostra a **impressão digital** do robô e pergunta se você confia:

```
The authenticity of host 'hexapod.local' can't be established.
ED25519 key fingerprint is SHA256:....
Are you sure you want to continue connecting (yes/no)?
```

Responda `yes`: o SSH guarda, e daí em diante **avisa se outra máquina tentar se passar pelo robô**. Você entrou quando aparecer `hexasys@hexapod:~ $`. Para sair, `exit`.

Sua rede não tem mDNS (`Could not resolve hostname`)? Use o IP do Pi que aparece no roteador: `ssh hexasys@192.168.x.x`.

## 4. Atalho: `ssh hexapod`

Acrescente ao `~/.ssh/config` (crie o arquivo se não existir):

```
Host hexapod
    HostName hexapod.local
    User hexasys
    IdentityFile ~/.ssh/id_ed25519
```

Agora `ssh hexapod`, `scp arquivo hexapod:/tmp/` e o Ansible usam isso. Com o acesso remoto (Tailscale) ligado, `HostName hexapod` alcança o robô de qualquer lugar.

## Já gravou o cartão sem a chave?

Se o Pi tem um usuário com senha, mande a chave uma vez:

```bash
ssh-copy-id hexasys@hexapod.local     # Linux, macOS (pede a senha uma última vez)
```

No Windows:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh hexasys@hexapod.local "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

## Uma chave para o deploy pelo GitHub (opcional)

O workflow `deploy` acessa o robô sozinho, então ele ganha **uma chave própria**, nunca a sua:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hexapod_ci -N "" -C "hexapod-ci"
ssh-copy-id -i ~/.ssh/hexapod_ci.pub hexasys@hexapod.local
ssh-keyscan hexapod > known_hosts_hexapod     # pelo Tailscale, como o workflow vê o robô
```

No repositório, **Settings → Secrets and variables → Actions**: `DEPLOY_SSH_KEY` = o conteúdo de `~/.ssh/hexapod_ci` (a privada, usada só pelo workflow) e `DEPLOY_KNOWN_HOSTS` = o conteúdo de `known_hosts_hexapod`. Para revogar depois, apague a linha dela no `~/.ssh/authorized_keys` do robô.

## Quando algo dá errado

| Mensagem | O que fazer |
|---|---|
| `Permission denied (publickey)` | O robô não tem esta chave pública: confira a linha colada no Imager, ou mande com `ssh-copy-id`. Com várias chaves: `ssh -i ~/.ssh/id_ed25519 hexasys@hexapod.local` |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` | Normal depois de **regravar o cartão** (o robô ganhou chaves de identidade novas): `ssh-keygen -R hexapod.local` e entre de novo. Se você não regravou nada, pare e descubra o porquê |
| `Could not resolve hostname hexapod.local` | A rede não tem mDNS: use o IP. No Windows, o mDNS funciona nas versões recentes; senão, use o IP |
| Pede a frase secreta toda vez | Carregue a chave uma vez por sessão: `ssh-add` (no macOS, `ssh-add --apple-use-keychain`) |
| `UNPROTECTED PRIVATE KEY FILE` | `chmod 600 ~/.ssh/id_ed25519` |

**Guarde bem a chave privada:** faça um backup num lugar privado (pendrive criptografado, gerenciador de senhas). Perdeu? Crie outra e mande a nova chave pública para o robô. Vazou? Remova a linha dela do `~/.ssh/authorized_keys` do robô.
