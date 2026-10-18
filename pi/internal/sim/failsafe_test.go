package sim

import (
	"testing"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

// Same transitions as firmware/test/test_failsafe, on a fake clock.
func TestFailsafeMatchesFirmware(t *testing.T) {
	f := NewFailsafe()
	t0 := time.Unix(1000, 0)
	healthy := Inputs{BatteryV: 11.4, DistancesMm: [4]uint32{1000, 1000, 1000, 1000}}
	at := func(ms int) time.Time { return t0.Add(time.Duration(ms) * time.Millisecond) }
	expect := func(ms int, want pb.State) {
		t.Helper()
		f.Update(healthy, at(ms))
		if f.State != want {
			t.Fatalf("t=%dms: state %v, want %v", ms, f.State, want)
		}
	}

	expect(0, pb.State_STATE_RELAXED) // boot
	f.OnCommand(&pb.Command{Seq: 1, Mode: pb.Mode_MODE_WALK}, at(0))
	expect(1, pb.State_STATE_RELAXED) // commands alone do not wake it
	f.OnCommand(&pb.Command{Seq: 2, Mode: pb.Mode_MODE_STAND}, at(10))
	expect(10, pb.State_STATE_NORMAL)
	expect(160, pb.State_STATE_NORMAL) // 150 ms after the last command
	expect(161, pb.State_STATE_STOPPING)
	expect(511, pb.State_STATE_SAFE_SIT)
	expect(10010, pb.State_STATE_SAFE_SIT) // exactly 10 s of silence
	expect(10011, pb.State_STATE_RELAXED)

	if f.OnCommand(&pb.Command{Seq: 2}, at(10100)) {
		t.Fatal("repeated seq accepted")
	}
	if !f.SetProfile(pb.LinkProfile_LINK_PROFILE_CELLULAR) {
		t.Fatal("profile change refused while relaxed")
	}
	f.OnCommand(&pb.Command{Seq: 3, Mode: pb.Mode_MODE_STAND}, at(10100))
	expect(10100, pb.State_STATE_NORMAL)
	if f.SetProfile(pb.LinkProfile_LINK_PROFILE_WIFI) {
		t.Fatal("profile change accepted while standing")
	}
	expect(10100+390, pb.State_STATE_NORMAL) // cellular: 400 ms
	expect(10100+410, pb.State_STATE_STOPPING)

	f.OnCommand(&pb.Command{Seq: 1, Estop: true}, at(10600)) // stale seq
	expect(10600, pb.State_STATE_ESTOP)
	if f.Posture != postRelax {
		t.Fatal("estop must relax")
	}
	f.OnCommand(&pb.Command{Seq: 4, Mode: pb.Mode_MODE_STAND}, at(10700))
	expect(10700, pb.State_STATE_NORMAL)
}

func TestFailsafeSensors(t *testing.T) {
	f := NewFailsafe()
	t0 := time.Unix(0, 0)
	in := Inputs{BatteryV: 11.4, DistancesMm: [4]uint32{1000, 1000, 1000, 1000}}
	f.OnCommand(&pb.Command{Seq: 1, Mode: pb.Mode_MODE_STAND}, t0)
	f.Update(in, t0)
	tick := func(ms int) {
		f.OnCommand(&pb.Command{Seq: f.LastSeq() + 1}, t0.Add(time.Duration(ms)*time.Millisecond))
		f.Update(in, t0.Add(time.Duration(ms)*time.Millisecond))
	}

	in.DistancesMm[0] = 120
	tick(20)
	if f.State != pb.State_STATE_BLOCKED || f.BlockedMask() != 1 {
		t.Fatalf("obstacle: %v mask %d", f.State, f.BlockedMask())
	}
	in.DistancesMm[0] = 1000
	tick(40)
	in.TiltDeg = 40
	for ms := 60; ms <= 200; ms += 20 {
		tick(ms)
	}
	if f.State != pb.State_STATE_TIPPED {
		t.Fatalf("tilt: %v", f.State)
	}
	in.TiltDeg = 0
	f.OnCommand(&pb.Command{Seq: f.LastSeq() + 1, Mode: pb.Mode_MODE_STAND}, t0.Add(220*time.Millisecond))
	f.Update(in, t0.Add(220*time.Millisecond))
	in.BatteryV = 9.6 // 3.2 V/cell
	for ms := 240; ms <= 2400; ms += 20 {
		tick(ms)
	}
	if f.State != pb.State_STATE_LOW_BATTERY {
		t.Fatalf("battery: %v", f.State)
	}
}
