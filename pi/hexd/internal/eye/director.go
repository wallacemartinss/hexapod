package eye

import (
	"math"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

// Situation is what is going on with the robot right now, as hexd sees it.
type Situation struct {
	Now       time.Time
	Telemetry *pb.Telemetry // nil: no ESP32 yet (or it went quiet)
	Apps      int           // apps connected
	Command   *pb.Command   // the last one an app sent (nil: none)
	CommandAt time.Time
	Network   bool // the Pi has an address (boot)
	Recording bool
	Photos    int  // photos taken so far (a change plays the shutter)
	Paired    bool // some app paired already (else the QR stays up)
	PairQR    string
	PairCode  string
	Shutdown  bool // hexd is stopping
}

// Director turns Situations into the eye's Inputs, remembering what it
// needs over time: when an app left, how long the robot idled, recent
// emergency stops, the gestures and events to play once.
type Director struct {
	start     time.Time
	booted    bool
	bootDone  time.Time
	appsWas   int
	appLeft   time.Time
	paired    bool
	pairSeen  bool
	pairedAt  time.Time
	stateWas  pb.State
	stateAt   time.Time
	stops     []time.Time
	gasWas    bool
	sneezes   int
	gesture   pb.Gesture
	winks     int
	reaction  Mood // a short mood a gesture asked for
	reactTill time.Time
	moved     time.Time
}

// NewDirector starts counting from now.
func NewDirector(now time.Time) *Director {
	return &Director{start: now, moved: now, stateAt: now}
}

// Thresholds of the moods (they read as they say).
const (
	scaredTilt   = 25.0             // degrees, before TIPPED at 35
	sadFor       = 15 * time.Second // after the app's signal is lost
	dozeAfter    = 2 * time.Minute  // relaxed, nobody around
	boredAfter   = time.Minute      // standing, no stick
	furyStops    = 3                // emergency stops within furyWindow
	furyWindow   = 30 * time.Second
	steerLatest  = 400 * time.Millisecond
	pairQRShown  = 10 * time.Second // when paired and no app: QR this long...
	pairQRPeriod = 25 * time.Second // ...in every period (the eye the rest)
)

// Inputs decides the eye for this moment.
func (d *Director) Inputs(s Situation) Inputs {
	in := Inputs{Boot: -1, Recording: s.Recording, Photo: s.Photos}
	t := s.Telemetry

	// Boot: the ring fills as the network and the ESP32 come up, then a
	// short happy look.
	if !d.booted {
		p, label := 0.33, "REDE"
		if s.Network {
			p, label = 0.66, "ESP32"
		}
		if t != nil {
			d.booted, d.bootDone = true, s.Now
		} else if s.Now.Sub(d.start) < 2*time.Minute { // never stuck in boot
			in.Boot, in.BootLabel = p, label
			return in
		}
	}

	// Remember changes.
	if s.Apps == 0 && d.appsWas > 0 {
		d.appLeft = s.Now
	}
	d.appsWas = s.Apps
	if d.pairSeen && s.Paired && !d.paired {
		d.pairedAt = s.Now // paired just now (not: already paired at boot)
	}
	d.paired, d.pairSeen = s.Paired, true
	if t != nil && t.State != d.stateWas {
		if t.State == pb.State_STATE_ESTOP {
			d.stops = append(d.stops, s.Now)
		}
		d.stateWas, d.stateAt = t.State, s.Now
	}
	for len(d.stops) > 0 && s.Now.Sub(d.stops[0]) > furyWindow {
		d.stops = d.stops[1:]
	}
	gas := t != nil && t.GasAlarm
	if gas && !d.gasWas {
		d.sneezes++ // gas detected: achoo!
	}
	d.gasWas = gas
	in.Sneeze = d.sneezes

	// The sticks: the eye looks where the pilot steers; gestures react.
	if c := s.Command; c != nil && s.Now.Sub(s.CommandAt) < steerLatest {
		turn := float64(c.Vy) + float64(c.YawRate) // left is positive on both
		if math.Abs(turn) > 0.05 || math.Abs(float64(c.Vx)) > 0.05 {
			in.Steering = true
			// The robot's left is the right of whoever faces it: +X on the panel.
			in.LookX = clampF(turn, -1, 1)
			in.LookY = clampF(-float64(c.Vx)*0.5, -1, 1)
			d.moved = s.Now
		}
		if c.Gesture != d.gesture {
			switch c.Gesture {
			case pb.Gesture_GESTURE_WAVE:
				d.winks++
			case pb.Gesture_GESTURE_STRIKE:
				d.reaction, d.reactTill = Hunter, s.Now.Add(4*time.Second) // eliminate the target
			case pb.Gesture_GESTURE_GUARD:
				d.reaction, d.reactTill = Surprised, s.Now.Add(2*time.Second)
			}
			d.gesture = c.Gesture
		}
	}
	in.Wink = d.winks

	in.Mood = d.mood(s, t)
	// Pairing QR: always until the first pairing; then, with no app, now
	// and then between looks around.
	if s.PairQR != "" && s.Apps == 0 && !s.Shutdown {
		if !s.Paired || s.Now.Sub(d.start)%pairQRPeriod < pairQRShown {
			in.PairQR, in.PairCode = s.PairQR, s.PairCode
		}
	}
	return in
}

func (d *Director) mood(s Situation, t *pb.Telemetry) Mood {
	switch {
	case s.Shutdown:
		return Sleeping
	case s.Now.Before(d.reactTill):
		return d.reaction
	case !d.pairedAt.IsZero() && s.Now.Sub(d.pairedAt) < 4*time.Second:
		return Love // just paired
	case s.Now.Sub(d.bootDone) < 2*time.Second:
		return Happy // up and running
	case t == nil:
		return Thinking // waiting for the ESP32
	}
	tilt := math.Max(math.Abs(float64(t.RollDeg)), math.Abs(float64(t.PitchDeg)))
	lost := s.Apps == 0 && !d.appLeft.IsZero() && s.Now.Sub(d.appLeft) < sadFor
	switch t.State {
	case pb.State_STATE_TIPPED:
		return Dizzy
	case pb.State_STATE_ESTOP:
		if len(d.stops) >= furyStops {
			return Furious
		}
		return Danger
	case pb.State_STATE_LOW_BATTERY:
		return Danger
	}
	switch {
	case tilt > scaredTilt:
		return Scared
	case t.GasAlarm:
		return Gas
	case lost:
		return Sad
	}
	switch t.State {
	case pb.State_STATE_STOPPING, pb.State_STATE_SAFE_SIT, pb.State_STATE_BLOCKED:
		return Alert
	}
	if t.FaultFlags&uint32(pb.Fault_FAULT_BATTERY_LOW) != 0 {
		return Tired
	}
	if t.State == pb.State_STATE_RELAXED {
		if s.Apps == 0 && s.Now.Sub(d.stateAt) > dozeAfter {
			return Dozing
		}
		if s.Apps == 0 {
			return Searching
		}
		return Relaxed
	}
	if s.Apps == 0 {
		return Searching
	}
	if s.Now.Sub(d.moved) > boredAfter {
		return Bored
	}
	return Ready
}

func clampF(x, lo, hi float64) float64 { return clamp(x, lo, hi) }
