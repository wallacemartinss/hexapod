package vision

import "math"

// Drive is how the robot follows: turn to keep the target centred, walk to
// keep it at Distance. Outputs are Command units (-1..1); the ESP32 turns
// them into speeds under its own limits and failsafe.
type Drive struct {
	Distance  float64 // m kept from the target
	Band      float64 // m around Distance with no walking (no hunting back and forth)
	MaxSpeed  float64 // vx limit, 0..1
	MaxBack   float64 // backing away from a target that comes too close, 0..1
	SpeedGain float64 // vx per metre of distance error
	MaxTurn   float64 // yaw_rate limit, 0..1
	TurnGain  float64 // yaw_rate per degree of bearing
	Deadband  float64 // degrees of bearing ignored
	TurnFirst float64 // degrees: farther off than this, turn before walking
}

// DefaultDrive: slow and gentle, for a first walk behind someone.
func DefaultDrive() Drive {
	return Drive{Distance: 1.2, Band: 0.2, MaxSpeed: 0.5, MaxBack: 0.2, SpeedGain: 0.6,
		MaxTurn: 0.6, TurnGain: 0.6 / 30, Deadband: 3, TurnFirst: 25}
}

// Steer turns the target's bearing (deg, + = left) and distance (m, 0 =
// unknown) into vx and yaw_rate. With the distance unknown it only turns.
func (d Drive) Steer(bearingDeg, distanceM float64) (vx, yawRate float64) {
	if math.Abs(bearingDeg) > d.Deadband {
		yawRate = clamp(bearingDeg*d.TurnGain, -d.MaxTurn, d.MaxTurn) // + bearing (left) = + yaw (left)
	}
	if distanceM <= 0 || math.Abs(bearingDeg) > d.TurnFirst {
		return 0, yawRate
	}
	if err := distanceM - d.Distance; math.Abs(err) > d.Band {
		vx = clamp(err*d.SpeedGain, -d.MaxBack, d.MaxSpeed)
	}
	return vx, yawRate
}

func clamp(x, lo, hi float64) float64 { return math.Max(lo, math.Min(hi, x)) }
