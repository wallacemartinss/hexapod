package sim

import (
	"math"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

// Failsafe mirrors firmware/src/safety/failsafe.cpp closely enough for hexd
// and the app to be tested against it: link-loss escalation per profile,
// estop, tipping, blocked directions, battery levels and STAND-only recovery.
// The firmware is the reference; its constants live in firmware config.h.
type Failsafe struct {
	profile    pb.LinkProfile
	hasCommand bool
	lastSeq    uint32
	lastValid  time.Time
	pendStand  bool

	latched     linkStage
	estop       bool
	tipped      bool
	critical    bool
	batteryLow  bool
	blockedMask uint32

	tiltSince, lowSince, critSince time.Time

	State pb.State
	// Posture: 0 follow, 1 stop, 2 sit, 3 relax (same order as the firmware).
	Posture int
}

type linkStage int

const (
	stageOK linkStage = iota
	stageStopping
	stageSafeSit
	stageRelaxed
)

// Same values as firmware/include/config.h.
const (
	wifiStop, wifiSit      = 150 * time.Millisecond, 500 * time.Millisecond
	cellStop, cellSit      = 400 * time.Millisecond, 1500 * time.Millisecond
	relaxAfter             = 10 * time.Second
	tippedDeg, releaseDeg  = 35.0, 30.0
	tippedDebounce         = 100 * time.Millisecond
	blockMm, releaseMm     = 150, 200
	cellLowV, cellCritV    = 3.5, 3.3
	cellHystV              = 0.1
	batteryDebounce        = 2 * time.Second
	batteryCells           = 3
	faultIMU, faultBattLow = 4, 128
	faultBattCrit          = 256
)

// Postures, least to most restrictive (firmware safety::Posture).
const (
	postFollow = iota
	postStop
	postSit
	postRelax
)

// NewFailsafe starts relaxed, like the firmware after boot.
func NewFailsafe() *Failsafe {
	return &Failsafe{profile: pb.LinkProfile_LINK_PROFILE_WIFI, latched: stageRelaxed,
		State: pb.State_STATE_RELAXED, Posture: postRelax}
}

// OnCommand applies the seq rule; estop latches even with a stale seq.
func (f *Failsafe) OnCommand(c *pb.Command, now time.Time) bool {
	valid := c.Seq > f.lastSeq
	if valid {
		f.lastSeq, f.lastValid, f.hasCommand = c.Seq, now, true
	}
	if c.Estop {
		f.estop, f.pendStand = true, false
	} else if valid && c.Mode == pb.Mode_MODE_STAND {
		f.pendStand = true
	}
	return valid
}

// SetProfile is only accepted while seated or relaxed.
func (f *Failsafe) SetProfile(p pb.LinkProfile) bool {
	if f.Posture < postSit || (p != pb.LinkProfile_LINK_PROFILE_WIFI && p != pb.LinkProfile_LINK_PROFILE_CELLULAR) {
		return false
	}
	f.profile = p
	return true
}

// LastSeq is the last accepted Command.seq (reported in Telemetry).
func (f *Failsafe) LastSeq() uint32 { return f.lastSeq }

// Inputs are the simulated sensor readings.
type Inputs struct {
	TiltDeg     float64
	BatteryV    float64
	DistancesMm [4]uint32
}

func debounced(cond bool, since *time.Time, now time.Time, hold time.Duration) bool {
	if !cond {
		*since = time.Time{}
		return false
	}
	if since.IsZero() {
		*since = now
	}
	return now.Sub(*since) >= hold
}

// Update runs one 50 Hz cycle and returns the fault flags.
func (f *Failsafe) Update(in Inputs, now time.Time) uint32 {
	if debounced(in.TiltDeg > tippedDeg, &f.tiltSince, now, tippedDebounce) {
		f.tipped = true
	}
	cell := in.BatteryV / batteryCells
	if debounced(cell < cellCritV, &f.critSince, now, batteryDebounce) {
		f.critical = true
	}
	if debounced(cell < cellLowV, &f.lowSince, now, batteryDebounce) {
		f.batteryLow = true
	} else if cell >= cellLowV+cellHystV {
		f.batteryLow = false
	}
	for i, d := range in.DistancesMm {
		bit := uint32(1) << i
		if d < blockMm {
			f.blockedMask |= bit
		} else if d > releaseMm {
			f.blockedMask &^= bit
		}
	}

	if f.pendStand {
		f.pendStand = false
		f.latched, f.estop = stageOK, false
		if f.tipped && in.TiltDeg <= releaseDeg {
			f.tipped = false
		}
		if f.critical && cell >= cellCritV+cellHystV {
			f.critical = false
		}
	}

	stage := stageRelaxed
	if f.hasCommand {
		silence := now.Sub(f.lastValid)
		stop, sit := wifiStop, wifiSit
		if f.profile == pb.LinkProfile_LINK_PROFILE_CELLULAR {
			stop, sit = cellStop, cellSit
		}
		switch {
		case silence > relaxAfter:
			stage = stageRelaxed
		case silence > sit:
			stage = stageSafeSit
		case silence > stop:
			stage = stageStopping
		default:
			stage = stageOK
		}
	}
	f.latched = max(f.latched, stage)

	posture := []int{postFollow, postStop, postSit, postRelax}[f.latched]
	if f.critical {
		posture = max(posture, postSit)
	}
	if f.estop || f.tipped {
		posture = postRelax
	}
	f.Posture = posture

	switch {
	case f.estop:
		f.State = pb.State_STATE_ESTOP
	case f.tipped:
		f.State = pb.State_STATE_TIPPED
	case f.critical:
		f.State = pb.State_STATE_LOW_BATTERY
	case f.latched == stageRelaxed:
		f.State = pb.State_STATE_RELAXED
	case f.latched == stageSafeSit:
		f.State = pb.State_STATE_SAFE_SIT
	case f.latched == stageStopping:
		f.State = pb.State_STATE_STOPPING
	case f.blockedMask != 0:
		f.State = pb.State_STATE_BLOCKED
	default:
		f.State = pb.State_STATE_NORMAL
	}

	var faults uint32
	if f.batteryLow {
		faults |= faultBattLow
	}
	if f.critical {
		faults |= faultBattCrit
	}
	if math.IsNaN(in.TiltDeg) {
		faults |= faultIMU
	}
	return faults
}

// BlockedMask reports the directions currently blocked.
func (f *Failsafe) BlockedMask() uint32 { return f.blockedMask }
