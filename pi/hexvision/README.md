# hexvision

**English** · [Português](README.pt-BR.md)

Follow me, the robot's side (ADR-0017 and the roadmap): hexvision reads the camera, finds the targets and sends them to hexd, which passes them to the app. The app draws a box on each target over the video; the pilot taps one and asks to follow it.

```
camera -> MediaMTX (rtsp://127.0.0.1:8554/cam) -> hexvision -> UDP 127.0.0.1:47300 -> hexd -> app
```

- **People:** MobileNet-SSD (MIT licence) through OpenCV's dnn module. A tracker keeps the same id on the same person from frame to frame, and brings it back by the colours of their clothes after a short occlusion.
- **ArUco markers** (`DICT_4X4_50`), e.g. on the phone's screen: only for close range (~1 m measured with a phone screen; a printed A4 marker reaches ~4 m).
- **Per target:** box in the image, bearing (+ = robot's left), elevation and distance (a person's from the height of the whole body, a marker's from its size).
- **No flukes:** a target reaches the app only after 3 frames in a row.
- **Separate process** from hexd: if the vision stops or crashes, the link to the ESP32 does not notice.
- **Nothing moves from here.** Following (F2) turns the locked target into Commands in hexd, still under the ESP32 failsafe.

## On a PC, with a webcam

```bash
cd proto && buf generate --template buf.gen.vision.yaml      # Python messages (needs protoc)
cd ../pi/hexvision
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
./get_models.sh                                              # person detector (23 MB, checked by SHA-256)
.venv/bin/python -m hexvision --source 0 --show --models models   # 0 = first webcam; Esc quits
.venv/bin/python -m unittest discover -s tests -t .          # tests (synthetic images)
```

Stand in front of the webcam (or show it a `DICT_4X4_50` marker): the window shows the box, bearing and distance. With hexd running on the same PC, the targets also reach the app.

## On the robot

Installed by the deploy (`/opt/hexapod/current/hexvision`) and run by `hexvision.service` (below hexd's priority, at most 1.5 cores). Ansible installs `python3-opencv` and `python3-protobuf`, and downloads the person detector to `/opt/hexapod/shared/models/mobilenet-ssd` (without it, markers only).

| Option | Default | |
|---|---|---|
| `--source` | `rtsp://127.0.0.1:8554/cam` | camera URL or webcam index |
| `--width` | 960 | processing width (a phone-screen marker needs ~7 px a side) |
| `--fps` | 15 | at most |
| `--hfov` | 100 | horizontal field of view without a lens calibration, degrees |
| `--calibration` | `/opt/hexapod/shared/config/camera_calibration.json` | lens calibration (F0): angles and distances measured, not estimated |
| `--marker-size` | 0.05 | marker's black square, m |
| `--models` | `/opt/hexapod/shared/models/mobilenet-ssd` | person detector |
| `--people-min` | 0.5 | person detector confidence, 0..1 |

Cost: the person detector takes ~30 ms a frame on one core of a desktop PC; a Pi 3 core is 10-15 times slower (to be measured on the robot), a Pi 4 about 3 times faster than a Pi 3.
