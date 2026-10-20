# GPS navigation

**English** · [Português](navegacao-gps.md)

The robot walks by itself to a point on the map, goes home, patrols a route and stays inside a virtual fence. All from the app's **Map** screen (map icon at the top of the pilot screen).

> **Status:** ready in the simulator. On the real robot, driving stays **off** (`nav.drive: false` in `hexd.yaml`) until the servos are calibrated and the first test is done with a hand on STOP.

## How to use

1. Switch the robot on **under open sky**. The GPS takes seconds to minutes to find its position. **Home** is set by itself where the robot was switched on (or with **Home here**).
2. Stand the robot up and put it in **Walk** mode.
3. On the Map screen:
   - tap a point, then **Go here**;
   - or **Go home**;
   - or draw a **Route** (tap the points in order, **Save**) and **Patrol** it (with **Repeat**, it starts over at the end);
   - the **Fence** is drawn the same way (3 corners or more).
4. **Release the sticks:** the robot turns towards the point and walks. It goes slowly (up to ~5 cm/s) and stops about 3 m from the point, which is how far off the GPS can be.

## Safety: as in follow me

- **The app is the dead man.** The robot only walks while the app is connected and sending walk-mode commands. No app, nothing walks.
- **A stick or STOP cancels** the mission at once.
- **Lost the link?** The ESP32 stops the robot, as always. When the app is back, it offers **Resume mission**. It never comes back on its own.
- **Obstacle ahead** (front distance sensor): the mission waits. There is no automatic detour.
- **Fence:** points beyond it are refused. If the robot ends up outside (carried, or by the GPS error), the mission stops and the pilot can only turn or walk **back in**.
- **Low battery:** the app suggests going home.

## Where the robot faces

At 8 cm/s the robot is too slow for the GPS to tell its heading by itself, so three sources work together:

- the BNO085's **compass** (magnetometer) knows north, but the servos' currents bend it;
- the **gyro** is smooth but does not know north;
- the **GPS**: every 10 m walked straight, the measured track corrects the compass' error.

**Magnetic declination:** compass north is not map north (about -21° in São Paulo). Put your city's value in `nav.declination` ([magnetic-declination.com](https://www.magnetic-declination.com/)). Left at 0, the GPS corrects it while walking, but the first tens of metres come out crooked.

## Trying it without a robot (simulator)

```bash
cd pi
go build -o bin/hexsim ./hexsim && go build -o bin/hexctl ./cmd/hexctl && (cd hexd && go build -o ../bin/hexd ./cmd/hexd)
bin/hexsim -listen tcp://127.0.0.1:7777 -gps tcp://127.0.0.1:7778 -speed 10 &
# development hexd.yaml: serial.device tcp://127.0.0.1:7777, gps.device tcp://127.0.0.1:7778,
# nav.drive true, auth.required false (and the hardware parts off)
bin/hexd -config my-hexd.yaml &
bin/hexctl -url ws://127.0.0.1:8080/ws goto -23.55032 -46.63310   # or from the app: make run
```

hexsim simulates the compass (with -21° declination and noise) and a GPS with the NEO-6M's typical error, served as NMEA. `-speed 10` speeds the walk up for a demo.

## Configuration (`hexd.yaml`, `nav:` block)

| Key | Default | |
|---|---|---|
| `enabled` | `true` | missions, home, fence and route (needs the GPS) |
| `drive` | `false` | hexd drives the robot during a mission. **Only after testing** |
| `arrive_m` | 3 | distance that counts as "arrived", m |
| `max_hdop` | 3 | poorer positions are ignored |
| `declination` | 0 | degrees; true = magnetic + this |
| `max_speed`, `max_turn` | 0.6 | share of the walking and turning speed |
| `store` | `/opt/hexapod/shared/config/nav.json` | the fence and the route are kept here |

The fence only counts near where it was drawn (up to 1 km): taking the robot somewhere else does not leave it "stuck outside".

## Known limits

- The NEO-6M is 2 to 5 m off: fine for a garden, a square or a field, not for "go to the door".
- No obstacle avoidance: with something ahead, the robot waits.
- The compass still has to be checked on the assembled robot (`kImuNorthYawDeg` in `config.h`, away from the servos' cables).
