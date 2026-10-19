# Installing the Hexapod

**English** · [Português](instalar.md)

This guide is for people who **don't use a terminal**: you flash a card on the PC, switch the robot on and set everything up from your phone. If you want to tinker with the system (SSH, Ansible), the maker path is in [`pi/provision/README.md`](../pi/provision/README.md).

## What you need

- The assembled robot, with the **Raspberry Pi 3** and the **ESP32-S3** connected.
- A **microSD card** of 16 GB or more.
- A **PC** with a card reader.
- An **Android 10 or newer phone**.
- **Proper power.** With a weak supply, the Raspberry Pi turns its Wi-Fi off and the screen goes dark. On the robot, power comes from the battery through the regulator. On the bench, use the official Raspberry Pi supply (5.1 V / 2.5 A). A phone charger won't do.

## 1. Flash the card (on the PC, once)

1. On the project's **Releases** page, download the file `hexapod-…-esp32s3.img.xz`. No need to unzip it.
2. Install **Raspberry Pi Imager**: [raspberrypi.com/software](https://www.raspberrypi.com/software/).
3. In the Imager:
   - **Device:** Raspberry Pi 3.
   - **Operating system:** scroll to the end → **Use custom** → pick the downloaded file.
   - **Storage:** your card. Check the size, so you don't erase another disk.
4. When the Imager asks whether you want to **customize**, you can answer **No**. The robot sets itself up.
   - Optional: if you already want the robot on your home network, enter the **Wi-Fi** there. Only **2.4 GHz** networks: the Raspberry Pi 3's Wi-Fi can't see 5 GHz.
5. **Write.** Wait until it finishes writing and verifying.

## 2. Switch the robot on

1. Put the card in the Raspberry Pi and switch the robot on.
2. The small screen shows **"HEXAPOD · INICIANDO"** (starting) and ticks off the system, the network, the ESP32 and the bridge. The robot's screen is in Portuguese for now.
3. **The first time takes about 2 minutes.** The robot fits the card and programs the ESP32 by itself. Don't switch it off meanwhile.
4. Then the screen cycles through three pages. One of them has a **QR code** and a **code of 5 letters and numbers**, like `K7F2Q`.

## 3. Pair the phone

1. Install the **Hexapod** app (soon on Google Play).
2. Open the app and tap **Pair a robot**.
3. **Point the camera at the QR code** on the robot's screen, or **type the 5-character code** shown next to it.
4. Android asks whether you want to connect to the **"Hexapode-…"** network: tap **Connect**. If a list shows up, pick the network with your robot's name.
5. Done: **"Paired!"**.

The code changes every 10 minutes and after each use. If the app says "wrong or expired code", use the one on the screen now.

## 4. Home Wi-Fi (optional)

Without setting anything up, the robot creates **its own network** and the phone connects to it. That works anywhere, even in a backyard with no router. To use your home network:

1. In the app: **Settings → Robot's network (Wi-Fi) → Connect to a network**.
2. Choose your network and type the password. It is stored **only on the robot**.
3. If the password is wrong, the robot **goes back to its own network by itself**, and the app tells you why.

## If something goes wrong

| What happens | What to do |
|---|---|
| The screen stays dark or "blinks" | It's almost always power: change the supply or the cable |
| The app doesn't find the robot | Phone and robot must be on the same network. On the "Couldn't find the robot" screen, enter the IP shown on the robot's screen |
| "Wrong or expired code" | Use the code on the screen **now** (it changes) |
| The "Hexapode-…" network doesn't show up | The Raspberry Pi's Wi-Fi didn't start: power again. Wait 1 minute after switching on |
| The screen shows **"ESP32 sem resposta"** (ESP32 not answering) | Check the USB cable between the Raspberry Pi and the ESP32 |
