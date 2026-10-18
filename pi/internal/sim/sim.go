// Package sim simulates the ESP32 firmware on any byte stream (TCP, Unix
// socket, PTY or an in-process pipe), speaking the real wire protocol.
package sim

import (
	"context"
	"io"
	"math"
	"math/rand/v2"
	"sync"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"github.com/wallacemartinss/hexapod/pi/internal/link"
	"google.golang.org/protobuf/proto"
)

// Options tune the simulation.
type Options struct {
	FirmwareVersion string
	GitHash         string
	// BootNoise sends garbage before the first frame, like the ESP32 ROM log.
	BootNoise bool
	// BatteryDrain multiplies the battery discharge (1 = realistic-ish).
	BatteryDrain float64
	// Now overrides the clock (tests).
	Now func() time.Time
}

// Sim is one simulated ESP32. It keeps its state (seq, failsafe, battery)
// across connections, like a board that stays powered while hexd restarts.
type Sim struct {
	opt Options

	mu       sync.Mutex
	fs       *Failsafe
	booted   time.Time
	mode     pb.Mode
	vx, vy   float32
	paws     *pb.FrontLegs
	gesture  pb.Gesture
	gestureT float64 // s left in the current gesture
	battery  float64 // V, open circuit
	tilt     float64 // deg, injected
	dist     [4]uint32
	telSeq   uint32
	faults   uint32
	walkTime float64
	rng      *rand.Rand
}

// New creates a simulator with a full 3S battery.
func New(opt Options) *Sim {
	if opt.Now == nil {
		opt.Now = time.Now
	}
	if opt.FirmwareVersion == "" {
		opt.FirmwareVersion = "hexsim"
	}
	if opt.BatteryDrain == 0 {
		opt.BatteryDrain = 1
	}
	return &Sim{opt: opt, fs: NewFailsafe(), booted: opt.Now(), mode: pb.Mode_MODE_SIT,
		battery: 12.4, dist: [4]uint32{1200, 900, 1500, 800}, rng: rand.New(rand.NewPCG(1, 2))}
}

// InjectTilt and InjectDistance drive the failsafe from tests or the CLI.
func (s *Sim) InjectTilt(deg float64) { s.mu.Lock(); s.tilt = deg; s.mu.Unlock() }

// InjectDistance sets the reading of distance sensor i (0 front, 1 right, 2 rear, 3 left).
func (s *Sim) InjectDistance(i int, mm uint32) { s.mu.Lock(); s.dist[i] = mm; s.mu.Unlock() }

// SetBattery sets the open-circuit battery voltage.
func (s *Sim) SetBattery(v float64) { s.mu.Lock(); s.battery = v; s.mu.Unlock() }

// State returns the current failsafe state.
func (s *Sim) State() pb.State { s.mu.Lock(); defer s.mu.Unlock(); return s.fs.State }

// Serve runs the simulator on rw until ctx ends or the stream fails.
func (s *Sim) Serve(ctx context.Context, rw io.ReadWriter) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	out := make(chan []byte, 32)
	errc := make(chan error, 2)

	go func() { // writer
		for {
			select {
			case <-ctx.Done():
				return
			case b := <-out:
				if _, err := rw.Write(b); err != nil {
					errc <- err
					return
				}
			}
		}
	}()
	send := func(env *pb.Envelope) {
		if frame, err := link.EncodeEnvelope(env); err == nil {
			select {
			case out <- frame:
			case <-ctx.Done():
			}
		}
	}

	if s.opt.BootNoise {
		select {
		case out <- []byte("ets Jun  8 2016 00:22:57\r\nrst:0x1 (POWERON_RESET)\x00\xff\x13\x00"):
		case <-ctx.Done():
		}
	}
	send(s.hello())

	go func() { // reader
		var dec link.Decoder
		buf := make([]byte, 256)
		for {
			n, err := rw.Read(buf)
			if err != nil {
				errc <- err
				return
			}
			for _, b := range buf[:n] {
				payload, err := dec.Push(b)
				if err != nil || payload == nil {
					continue
				}
				var env pb.Envelope
				if proto.Unmarshal(payload, &env) != nil {
					continue
				}
				if reply := s.handle(&env); reply != nil {
					send(reply)
				}
			}
		}
	}()

	motion := time.NewTicker(20 * time.Millisecond)
	defer motion.Stop()
	for n := 0; ; n++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-errc:
			return err
		case <-motion.C:
			s.step(0.02)
			if n%5 == 0 {
				send(s.telemetry())
			}
		}
	}
}

func (s *Sim) hello() *pb.Envelope {
	s.mu.Lock()
	defer s.mu.Unlock()
	return &pb.Envelope{Payload: &pb.Envelope_Hello{Hello: &pb.Hello{
		ProtocolVersion: 1, FirmwareVersion: s.opt.FirmwareVersion, GitHash: s.opt.GitHash,
		UptimeMs: uint32(s.opt.Now().Sub(s.booted).Milliseconds()),
	}}}
}

func (s *Sim) handle(env *pb.Envelope) *pb.Envelope {
	switch m := env.Payload.(type) {
	case *pb.Envelope_Hello:
		return s.hello()
	case *pb.Envelope_Command:
		s.mu.Lock()
		if s.fs.OnCommand(m.Command, s.opt.Now()) {
			if m.Command.Mode != pb.Mode_MODE_UNSPECIFIED {
				s.mode = m.Command.Mode
			}
			s.vx, s.vy = m.Command.Vx, m.Command.Vy
			s.paws = m.Command.FrontLegs
			if g := m.Command.Gesture; g != s.gesture && g != pb.Gesture_GESTURE_UNSPECIFIED && s.mode == pb.Mode_MODE_FRONT_LEGS {
				s.gestureT = 2.0 // roughly the firmware gesture lengths
			}
			s.gesture = m.Command.Gesture
		}
		s.mu.Unlock()
	case *pb.Envelope_LinkConfig:
		s.mu.Lock()
		s.fs.SetProfile(m.LinkConfig.Profile)
		s.mu.Unlock()
	}
	return nil
}

// step advances the physics: battery, failsafe, gait phase.
func (s *Sim) step(dt float64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.battery -= s.current() * dt / 3600 / 2.2 * 1.2 * s.opt.BatteryDrain // 2.2 Ah pack, rough
	s.faults = s.fs.Update(Inputs{TiltDeg: s.tilt, BatteryV: s.loadedVoltage(), DistancesMm: s.dist}, s.opt.Now())
	if s.walking() {
		s.walkTime += dt
	}
	if s.gestureT > 0 {
		s.gestureT -= dt
	}
}

func (s *Sim) walking() bool {
	return s.fs.Posture == postFollow && s.mode == pb.Mode_MODE_WALK && (s.vx != 0 || s.vy != 0)
}

// current draw in A by posture (rough MG996R figures).
func (s *Sim) current() float64 {
	switch {
	case s.fs.Posture == postRelax:
		return 0.3
	case s.walking():
		return 5.0
	case s.mode == pb.Mode_MODE_SIT || s.fs.Posture == postSit:
		return 1.5
	default:
		return 3.0
	}
}

func (s *Sim) loadedVoltage() float64 { return s.battery - s.current()*0.05 } // 50 mOhm

func (s *Sim) telemetry() *pb.Envelope {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.telSeq++
	sway := 0.0
	if s.walking() {
		sway = 2 * math.Sin(2*math.Pi*s.walkTime)
	}
	roll, pitch := sway+s.rng.NormFloat64()*0.2, s.rng.NormFloat64()*0.2+s.tilt
	qw, qx, qy, qz := quaternion(roll, pitch, 0)
	dist := make([]uint32, 4)
	for i, d := range s.dist {
		dist[i] = uint32(max(30, float64(d)+s.rng.NormFloat64()*5))
	}
	angles := make([]float32, 18)
	for leg := range 6 {
		femur, tibia := 35.0, -107.0 // standing
		if s.fs.Posture >= postSit || s.mode == pb.Mode_MODE_SIT {
			femur, tibia = 76.2, -118.1
		}
		if s.walking() {
			ph := 2*math.Pi*s.walkTime + float64(leg%2)*math.Pi
			femur += 10 * math.Max(0, math.Sin(ph))
		}
		// Front legs mode: paws 0 and 3 raised forward, moved by the sticks.
		if s.mode == pb.Mode_MODE_FRONT_LEGS && s.fs.Posture == postFollow && (leg == 0 || leg == 3) {
			reach, lift := float64(0), float64(0)
			if s.paws != nil {
				if leg == 0 {
					reach, lift = float64(s.paws.LeftReach), float64(s.paws.LeftLift)
				} else {
					reach, lift = float64(s.paws.RightReach), float64(s.paws.RightLift)
				}
			}
			if s.gestureT > 0 { // a gesture waves the paw
				lift = 1
				reach = 0.5 * math.Sin(2*math.Pi*s.gestureT/0.6)
			}
			femur, tibia = 42+12*lift-8*reach, -46+10*reach
		}
		angles[leg*3+1], angles[leg*3+2] = float32(femur), float32(tibia)
	}
	return &pb.Envelope{Payload: &pb.Envelope_Telemetry{Telemetry: &pb.Telemetry{
		Seq: s.telSeq, UptimeMs: uint32(s.opt.Now().Sub(s.booted).Milliseconds()),
		State: s.fs.State, FaultFlags: s.faults, LastCommandSeq: s.fs.LastSeq(),
		Mode: s.mode, Gait: pb.Gait_GAIT_TRIPOD,
		BatteryVoltageV: float32(s.loadedVoltage()), BatteryCurrentA: float32(s.current()),
		Orientation: &pb.Quaternion{W: qw, X: qx, Y: qy, Z: qz},
		RollDeg:     float32(roll), PitchDeg: float32(pitch),
		DistancesMm: dist, BlockedMask: s.fs.BlockedMask(),
		TemperatureC: 24.5, HumidityPct: 52, PressureHpa: 1013.2, Esp32TemperatureC: 46,
		LoopTimeUs: 300 + uint32(s.rng.IntN(40)), JointAnglesDeg: angles,
	}}}
}

// quaternion from roll, pitch, yaw in degrees (ZYX).
func quaternion(roll, pitch, yaw float64) (w, x, y, z float32) {
	r, p, ya := roll*math.Pi/360, pitch*math.Pi/360, yaw*math.Pi/360
	cr, sr, cp, sp, cy, sy := math.Cos(r), math.Sin(r), math.Cos(p), math.Sin(p), math.Cos(ya), math.Sin(ya)
	return float32(cr*cp*cy + sr*sp*sy), float32(sr*cp*cy - cr*sp*sy),
		float32(cr*sp*cy + sr*cp*sy), float32(cr*cp*sy - sr*sp*cy)
}
