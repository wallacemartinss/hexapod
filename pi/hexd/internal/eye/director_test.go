package eye

import (
	"testing"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

// clockSit steps a Situation through time.
type clockSit struct {
	d   *Director
	now time.Time
	s   Situation
}

func newClock() *clockSit {
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	return &clockSit{d: NewDirector(now), now: now, s: Situation{Paired: true}}
}

func (c *clockSit) at(after time.Duration) Inputs {
	c.now = c.now.Add(after)
	c.s.Now = c.now
	return c.d.Inputs(c.s)
}

func telem(state pb.State) *pb.Telemetry { return &pb.Telemetry{State: state} }

func TestDirectorBootThenHappyThenSearching(t *testing.T) {
	c := newClock()
	if in := c.at(0); in.Boot != 0.33 || in.BootLabel != "REDE" {
		t.Fatalf("boot: %+v", in)
	}
	c.s.Network = true
	if in := c.at(time.Second); in.Boot != 0.66 || in.BootLabel != "ESP32" {
		t.Fatalf("network up: %+v", in)
	}
	c.s.Telemetry = telem(pb.State_STATE_RELAXED)
	if in := c.at(time.Second); in.Boot >= 0 || in.Mood != Happy {
		t.Fatalf("ESP32 up: %+v", in)
	}
	if in := c.at(3 * time.Second); in.Mood != Searching {
		t.Errorf("no app: %v", in.Mood)
	}
	if in := c.at(3 * time.Minute); in.Mood != Dozing {
		t.Errorf("relaxed and alone for minutes: %v", in.Mood)
	}
}

func TestDirectorMoods(t *testing.T) {
	c := newClock()
	c.s.Telemetry = telem(pb.State_STATE_NORMAL)
	c.s.Apps = 1
	c.at(0)
	c.at(3 * time.Second)

	c.s.Telemetry = &pb.Telemetry{State: pb.State_STATE_NORMAL, RollDeg: 28}
	if in := c.at(time.Second); in.Mood != Scared {
		t.Errorf("tilting: %v", in.Mood)
	}
	c.s.Telemetry = telem(pb.State_STATE_TIPPED)
	if in := c.at(time.Second); in.Mood != Dizzy {
		t.Errorf("tipped: %v", in.Mood)
	}
	for i := 0; i < 3; i++ { // three emergency stops in a row
		c.s.Telemetry = telem(pb.State_STATE_ESTOP)
		in := c.at(time.Second)
		if want := map[bool]Mood{true: Furious, false: Danger}[i == 2]; in.Mood != want {
			t.Errorf("stop %d: %v, want %v", i+1, in.Mood, want)
		}
		c.s.Telemetry = telem(pb.State_STATE_NORMAL)
		c.at(time.Second)
	}
	c.at(time.Minute) // the stops are forgotten; nobody touched the sticks
	if in := c.at(time.Second); in.Mood != Bored {
		t.Errorf("idle for a minute: %v", in.Mood)
	}
	c.s.Telemetry = &pb.Telemetry{State: pb.State_STATE_NORMAL, GasAlarm: true}
	if in := c.at(time.Second); in.Mood != Gas || in.Sneeze != 1 {
		t.Errorf("gas: %v, sneezes %d", in.Mood, in.Sneeze)
	}
	c.s.Telemetry = telem(pb.State_STATE_NORMAL)
	c.s.Apps = 0
	if in := c.at(time.Second); in.Mood != Sad {
		t.Errorf("app lost: %v", in.Mood)
	}
	if in := c.at(20 * time.Second); in.Mood != Searching {
		t.Errorf("long after: %v", in.Mood)
	}
}

func TestDirectorSticksAndGestures(t *testing.T) {
	c := newClock()
	c.s.Telemetry = telem(pb.State_STATE_NORMAL)
	c.s.Apps = 1
	c.at(0)
	c.at(3 * time.Second)

	c.s.Command, c.s.CommandAt = &pb.Command{YawRate: 0.8}, c.now.Add(time.Second)
	in := c.at(time.Second)
	if !in.Steering || in.LookX <= 0 {
		t.Errorf("turning left: steering %v, look %.2f (want toward the robot's left, +X)", in.Steering, in.LookX)
	}
	c.s.Command = &pb.Command{Gesture: pb.Gesture_GESTURE_WAVE}
	c.s.CommandAt = c.now.Add(100 * time.Millisecond)
	if in := c.at(100 * time.Millisecond); in.Wink != 1 {
		t.Errorf("wave: wink %d", in.Wink)
	}
	c.s.Command = &pb.Command{Gesture: pb.Gesture_GESTURE_STRIKE}
	c.s.CommandAt = c.now.Add(100 * time.Millisecond)
	if in := c.at(100 * time.Millisecond); in.Mood != Hunter {
		t.Errorf("strike: %v, want the hunter", in.Mood)
	}
	if in := c.at(5 * time.Second); in.Mood == Hunter {
		t.Error("the hunter must not stay")
	}
}

func TestDirectorPairing(t *testing.T) {
	c := newClock()
	c.s.Telemetry = telem(pb.State_STATE_RELAXED)
	c.s.Paired, c.s.PairQR, c.s.PairCode = false, "HXP2 K7F2 Q8M3D", "Q8M3D"
	c.at(0)
	if in := c.at(30 * time.Second); in.PairQR == "" {
		t.Error("not paired yet: the QR must stay up")
	}
	c.s.Paired, c.s.Apps = true, 1
	in := c.at(time.Second)
	if in.PairQR != "" || in.Mood != Love {
		t.Errorf("just paired: QR %q, mood %v (want love)", in.PairQR, in.Mood)
	}
	c.s.Apps = 0 // paired, nobody connected: the QR comes and goes
	shown := 0
	for i := 0; i < 50; i++ {
		if c.at(time.Second).PairQR != "" {
			shown++
		}
	}
	if shown == 0 || shown == 50 {
		t.Errorf("QR shown %d of 50 s, want part of the time", shown)
	}
}

func TestDirectorFollowsTheLockedTarget(t *testing.T) {
	c := newClock()
	c.s.Telemetry = telem(pb.State_STATE_NORMAL)
	c.s.Apps = 1
	c.at(0)
	c.at(3 * time.Second)

	c.s.Follow = &pb.FollowStatus{State: pb.FollowState_FOLLOW_STATE_LOCKED, BearingDeg: 30}
	c.s.Locks = 1
	in := c.at(100 * time.Millisecond)
	if in.Mood != Hunter {
		t.Errorf("new lock: %v, want the hunter's lock-on", in.Mood)
	}
	if in.LookX < 0.6 || in.LookX > 0.7 {
		t.Errorf("target 30 deg to the left: look %.2f, want ~0.67", in.LookX)
	}
	in = c.at(5 * time.Second)
	if in.Mood != Ready || in.LookX <= 0 {
		t.Errorf("after the lock-on: %v look %.2f, want ready and still looking", in.Mood, in.LookX)
	}
	c.s.Follow = &pb.FollowStatus{State: pb.FollowState_FOLLOW_STATE_LOST, BearingDeg: -50}
	if in := c.at(100 * time.Millisecond); in.Mood != Searching || in.LookX != -1 {
		t.Errorf("lost: %v look %.2f, want searching where it went", in.Mood, in.LookX)
	}
	// The sticks win over the target.
	c.s.Follow.State = pb.FollowState_FOLLOW_STATE_LOCKED
	c.s.Command, c.s.CommandAt = &pb.Command{YawRate: 0.5}, c.now.Add(100*time.Millisecond)
	if in := c.at(100 * time.Millisecond); in.LookX != 0.5 {
		t.Errorf("steering while locked: look %.2f, want the stick's 0.5", in.LookX)
	}
}
