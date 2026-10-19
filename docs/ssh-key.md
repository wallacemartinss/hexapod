# SSH key: getting into the robot from your PC

**English** · [Português](chave-ssh.md)

Makers reach the robot's Raspberry Pi over **SSH**: a terminal on the Pi, from your PC, through the network. Ansible and the deploy use it too. This guide makes your **SSH key** and puts it on the robot, step by step. You do it once per PC.

> Only for the maker path. The simple path (ready-made image and the app) needs none of this.

## What a key is, and why not a password

An SSH key is a pair of files:

- **private key** (`id_ed25519`): stays on your PC, **never** shared. It is your identity.
- **public key** (`id_ed25519.pub`): goes to the robot. It is the "lock" that only your private key opens.

With a key, nobody can guess their way in with a password, and you log in without typing one (or with a passphrase that only unlocks the key on your own PC).

## 1. Make the key

### Linux and macOS

Open a terminal:

```bash
ssh-keygen -t ed25519 -C "hexasys"
```

- **File:** press Enter to keep the default (`~/.ssh/id_ed25519`). If it says the file exists, you already have a key: answer `n` and skip to step 2.
- **Passphrase:** recommended (it protects the key if someone copies your PC's files). You can leave it empty.

### Windows 10 / 11

Open **PowerShell** (OpenSSH comes with Windows) and run the same command:

```powershell
ssh-keygen -t ed25519 -C "hexasys"
```

The key goes to `C:\Users\<you>\.ssh\id_ed25519`.

### See your public key

```bash
cat ~/.ssh/id_ed25519.pub          # Linux, macOS
type $env:USERPROFILE\.ssh\id_ed25519.pub   # Windows PowerShell
```

It is one line starting with `ssh-ed25519 AAAA...` and ending with `hexasys`. That is what you copy. **Never copy the file without `.pub`.**

## 2. Put it on the robot while flashing the card

In **Raspberry Pi Imager**, choose **Raspberry Pi OS Lite (64-bit)** and, when it offers to **customize** the system:

1. **Hostname:** `hexapod`.
2. **User:** `hexasys`, with a password (used for `sudo`).
3. **Wi-Fi** and country, if you want it on your network (a Pi 3 only sees 2.4 GHz).
4. **SSH / remote access:** turn it on and choose **public-key authentication only**. Paste your public key (the `ssh-ed25519 ...` line). Recent Imager versions can read it from your PC by themselves.

Write the card, put it in the Pi, power on and wait a minute.

## 3. First login

```bash
ssh hexasys@hexapod.local
```

The first time, SSH shows the robot's **fingerprint** and asks whether to trust it:

```
The authenticity of host 'hexapod.local' can't be established.
ED25519 key fingerprint is SHA256:....
Are you sure you want to continue connecting (yes/no)?
```

Answer `yes`: SSH remembers it, and from then on it **warns you if another machine pretends to be the robot**. You are in when you see `hexasys@hexapod:~ $`. Leave with `exit`.

No mDNS on your network (`Could not resolve hostname`)? Use the Pi's IP from your router: `ssh hexasys@192.168.x.x`.

## 4. Shortcut: `ssh hexapod`

Add to `~/.ssh/config` (create the file if missing):

```
Host hexapod
    HostName hexapod.local
    User hexasys
    IdentityFile ~/.ssh/id_ed25519
```

Now `ssh hexapod`, `scp file hexapod:/tmp/` and the Ansible all use it. With remote access (Tailscale) on, `HostName hexapod` reaches the robot from anywhere.

## Already flashed without the key?

If the Pi has a user with a password, send the key once:

```bash
ssh-copy-id hexasys@hexapod.local     # Linux, macOS (asks for the password one last time)
```

On Windows:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh hexasys@hexapod.local "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

## A key for the deploy from GitHub (optional)

The `deploy` workflow reaches the robot on its own, so it gets **its own key**, never yours:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hexapod_ci -N "" -C "hexapod-ci"
ssh-copy-id -i ~/.ssh/hexapod_ci.pub hexasys@hexapod.local
ssh-keyscan hexapod > known_hosts_hexapod     # through Tailscale, as the workflow sees it
```

In the repository, **Settings → Secrets and variables → Actions**: `DEPLOY_SSH_KEY` = the content of `~/.ssh/hexapod_ci` (the private one, used only by the workflow) and `DEPLOY_KNOWN_HOSTS` = the content of `known_hosts_hexapod`. To revoke it later, delete its line from `~/.ssh/authorized_keys` on the robot.

## When something goes wrong

| Message | What to do |
|---|---|
| `Permission denied (publickey)` | The robot does not have this public key: check the line pasted in the Imager, or send it with `ssh-copy-id`. With several keys: `ssh -i ~/.ssh/id_ed25519 hexasys@hexapod.local` |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` | Normal after **re-flashing the card** (the robot got new identity keys): `ssh-keygen -R hexapod.local` and log in again. If you did not re-flash anything, stop and find out why |
| `Could not resolve hostname hexapod.local` | No mDNS on the network: use the IP. On Windows, mDNS works on recent versions; otherwise use the IP |
| It asks for the passphrase every time | Load the key once per session: `ssh-add` (on macOS, `ssh-add --apple-use-keychain`) |
| `UNPROTECTED PRIVATE KEY FILE` | `chmod 600 ~/.ssh/id_ed25519` |

**Keep the private key safe:** back it up somewhere private (an encrypted drive, a password manager). Lost it? Make a new one and send the new public key to the robot. Leaked it? Remove its line from `~/.ssh/authorized_keys` on the robot.
