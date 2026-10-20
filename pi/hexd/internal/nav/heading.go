package nav

import (
	"math"
	"time"
)

// Where the robot faces, from three sources that fail differently:
//
//   - the gyro (the game rotation vector's yaw in Telemetry): smooth and
//     never fooled by magnets, but its zero is arbitrary and drifts;
//   - the compass (Compass frames, the BNO085 rotation vector): knows
//     north, but the servos' currents and the battery bend it;
//   - the GPS: over a few metres walked straight, the track between two
//     fixes is the true heading. The robot is too slow (8 cm/s) for the
//     NEO-6M's own course, so only long straight walks count.
//
// The heading is the gyro plus an offset. The compass pulls the offset
// slowly (a magnetic spike moves it little), and each straight walk the
// GPS measures corrects the compass' bias (declination and the robot's
// own magnetism together).

const (
	compassTau     = 3.0              // s: how fast the compass pulls the offset
	compassMaxErr  = 30.0             // deg: a compass less sure than this is not used
	headingKeep    = 60 * time.Second // the gyro alone is trusted this long
	trackMinM      = 10.0             // straight walk that measures the heading
	trackMaxTurn   = 15.0             // deg off the walk's mean: not straight, start over
	trackGain      = 0.5              // share of each measured error corrected
	trackMaxHdop   = 2.0
	maxTrackSample = 2 * time.Second // gap that breaks a straight walk
)

// Heading is not safe for concurrent use (the Navigator holds its lock).
type Heading struct {
	Declination float64 // deg, true = magnetic + declination (before the GPS learns better)

	offset    float64 // true heading = offset - gyro yaw
	have      bool
	correctAt time.Time // last time the compass or the GPS corrected it
	bias      float64   // learnt by the GPS: true = magnetic + Declination + bias
	gpsFixed  bool      // the GPS measured it at least once
	lastAt    time.Time

	walking   bool
	walkFrom  Point
	walkAt    time.Time
	walkSin   float64
	walkCos   float64
	walkCount int
}

// Gyro and compass, every update. accuracy 0 = no compass.
func (h *Heading) Compass(now time.Time, gyroYaw, magnetic, accuracy float64) {
	dt := 0.1
	if !h.lastAt.IsZero() {
		dt = math.Min(1, now.Sub(h.lastAt).Seconds())
	}
	h.lastAt = now
	if accuracy <= 0 || accuracy > compassMaxErr {
		return
	}
	want := wrap360(magnetic+h.Declination+h.bias) + gyroYaw // the offset the compass says
	if !h.have {
		h.offset, h.have = wrap360(want), true
	} else {
		h.offset = wrap360(h.offset + wrap180(want-h.offset)*math.Min(1, dt/compassTau))
	}
	h.correctAt = now
}

// True heading (deg, true north, clockwise) for the gyro's yaw, and
// whether it is trusted.
func (h *Heading) True(now time.Time, gyroYaw float64) (float64, bool) {
	if !h.have {
		return 0, false
	}
	return wrap360(h.offset - gyroYaw), now.Sub(h.correctAt) < headingKeep
}

// GPSCorrected: a straight walk measured the compass' bias.
func (h *Heading) GPSCorrected() bool { return h.gpsFixed }

// Walk feeds a new GPS fix while the robot walks forward (straight is
// checked here); straight false (turning, stopped, sideways) starts over.
func (h *Heading) Walk(now time.Time, pos Point, hdop float64, straight bool, gyroYaw float64) {
	if !straight || hdop > trackMaxHdop || (h.walking && now.Sub(h.walkAt) > maxTrackSample) {
		h.walking = false
		if !straight || hdop > trackMaxHdop {
			return
		}
	}
	// Measured in the gyro's frame: its drift over a short walk is nothing.
	yaw := -gyroYaw * math.Pi / 180
	if !h.walking {
		h.walking, h.walkFrom, h.walkSin, h.walkCos, h.walkCount = true, pos, 0, 0, 0
	}
	if h.walkCount > 0 {
		mean := math.Atan2(h.walkSin, h.walkCos)
		if math.Abs(wrap180((yaw-mean)*180/math.Pi)) > trackMaxTurn {
			h.walking = false
			h.Walk(now, pos, hdop, straight, gyroYaw)
			return
		}
	}
	h.walkSin, h.walkCos, h.walkCount, h.walkAt = h.walkSin+math.Sin(yaw), h.walkCos+math.Cos(yaw), h.walkCount+1, now
	if Distance(h.walkFrom, pos) < trackMinM {
		return
	}
	track := Bearing(h.walkFrom, pos)
	meanYaw := -math.Atan2(h.walkSin, h.walkCos) * 180 / math.Pi // back to the gyro's sign
	if !h.have {
		h.offset, h.have = wrap360(track+meanYaw), true
	} else {
		e := wrap180(track - wrap360(h.offset-meanYaw))
		h.offset = wrap360(h.offset + trackGain*e)
		h.bias = wrap180(h.bias + trackGain*e)
	}
	h.gpsFixed, h.correctAt = true, now
	h.walking = false
}
