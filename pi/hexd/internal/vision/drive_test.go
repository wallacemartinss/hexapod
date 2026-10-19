package vision

import (
	"math"
	"testing"
)

func TestSteerSigns(t *testing.T) {
	d := DefaultDrive()
	cases := []struct {
		name               string
		bearing, distance  float64
		wantVx, wantYawSgn int
	}{
		{"ahead and far: walk", 0, 3, 1, 0},
		{"ahead at the distance: stay", 0, d.Distance, 0, 0},
		{"too close: back off", 0, 0.5, -1, 0},
		{"to the left: turn left", 15, 1.2, 0, 1},
		{"far right: turn first, no walking", -40, 3, 0, -1},
		{"distance unknown: only turn", 10, 0, 0, 1},
		{"inside the deadband: nothing", 2, 1.2, 0, 0},
	}
	sgn := func(x float64) int {
		switch {
		case x > 1e-9:
			return 1
		case x < -1e-9:
			return -1
		}
		return 0
	}
	for _, c := range cases {
		vx, yaw := d.Steer(c.bearing, c.distance)
		if sgn(vx) != c.wantVx || sgn(yaw) != c.wantYawSgn {
			t.Errorf("%s: vx %.2f yaw %.2f", c.name, vx, yaw)
		}
		if vx > d.MaxSpeed || vx < -d.MaxBack || math.Abs(yaw) > d.MaxTurn {
			t.Errorf("%s: over the limits (vx %.2f yaw %.2f)", c.name, vx, yaw)
		}
	}
}

// A robot on the floor with the ESP32's speeds (config.h: 80 mm/s and
// 20 deg/s at 1.0), seeing the target at 3 Hz with 300 ms of delay, like a
// Pi 3: it must end up facing the target at the distance, without
// oscillating.
func TestSteerClosedLoop(t *testing.T) {
	d := DefaultDrive()
	const maxSpeed, maxTurn = 0.08, 20.0 // m/s and deg/s at 1.0
	rx, ry, heading := 0.0, 0.0, 0.0     // robot, deg (0 = +x)
	tx, ty := 3.0, 1.5                   // target, m
	var vx, yaw float64
	type seen struct{ at, bearing, dist float64 }
	var queue []seen
	const dt, frame, delay = 0.02, 1.0 / 3, 0.3
	nextFrame := 0.0
	var turns int
	lastYawSign := 0.0
	for now := 0.0; now < 120; now += dt {
		if now >= nextFrame { // a camera frame, processed later
			nextFrame += frame
			b := math.Atan2(ty-ry, tx-rx)*180/math.Pi - heading
			queue = append(queue, seen{now + delay, math.Remainder(b, 360), math.Hypot(tx-rx, ty-ry)})
		}
		if len(queue) > 0 && queue[0].at <= now {
			vx, yaw = d.Steer(queue[0].bearing, queue[0].dist)
			queue = queue[1:]
			if s := math.Copysign(1, yaw); yaw != 0 && s != lastYawSign {
				turns++
				lastYawSign = s
			}
		}
		heading += yaw * maxTurn * dt
		h := heading * math.Pi / 180
		rx += vx * maxSpeed * dt * math.Cos(h)
		ry += vx * maxSpeed * dt * math.Sin(h)
	}
	dist := math.Hypot(tx-rx, ty-ry)
	bearing := math.Remainder(math.Atan2(ty-ry, tx-rx)*180/math.Pi-heading, 360)
	if math.Abs(dist-d.Distance) > d.Band+0.05 || math.Abs(bearing) > d.Deadband+1 {
		t.Fatalf("ended at %.2f m, %.1f deg off", dist, bearing)
	}
	if turns > 4 {
		t.Fatalf("turned back and forth %d times: oscillating", turns)
	}
}

func TestFuseCameraAndFrontSensor(t *testing.T) {
	for _, tc := range []struct {
		name                 string
		bearing, camera, tof float64
		want                 float64
	}{
		{"camera only", 0, 1.5, 0, 1.5},
		{"sensor only, ahead", 5, 0, 1.4, 1.4},
		{"sensor ignored off to the side", 25, 0, 1.4, 0},
		{"something in between: the nearer", 0, 1.5, 0.6, 0.6},
		{"beam between the legs: the nearer", 0, 1.2, 1.9, 1.2},
	} {
		if got := Fuse(tc.bearing, tc.camera, tc.tof); got != tc.want {
			t.Errorf("%s: got %.2f, want %.2f", tc.name, got, tc.want)
		}
	}
}
