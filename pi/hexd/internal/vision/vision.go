// Package vision receives follow-me targets from hexvision (UDP, one
// Envelope per frame) and keeps the pilot's choice: which target is
// followed, and whether it is in view.
//
// With following on (EnableFollow), Steer replaces the speeds of the app's
// own walk Commands with the ones that follow the locked target: the app
// stays the dead man (no Commands, nothing moves), any stick or STOP takes
// over, and the ESP32 failsafe applies as always.
package vision

import (
	"context"
	"log/slog"
	"math"
	"net"
	"sync"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"google.golang.org/protobuf/proto"
)

const (
	// StaleAfter: no Targets for this long and nothing is in view
	// (hexvision stopped, or the camera did).
	StaleAfter = 500 * time.Millisecond
	// ReleaseAfter: a lost target is waited for this long, then let go.
	ReleaseAfter = 5 * time.Second
	// TakeOver: a stick past this (any axis, -1..1) cancels following.
	TakeOver = 0.2
	// steerFresh: the robot counts as following while Steer drove it this recently.
	steerFresh = 300 * time.Millisecond
	// frontFresh: a front distance older than this is not used.
	frontFresh = 300 * time.Millisecond
	// frontMaxMm: the firmware caps readings here, meaning nothing in range.
	frontMaxMm = 2000
)

// Hub is safe for concurrent use.
type Hub struct {
	log *slog.Logger
	now func() time.Time

	mu        sync.Mutex
	latest    *pb.Targets
	latestAt  time.Time
	track     uint32 // locked target, 0 = none
	lastSeen  *pb.Target
	seenAt    time.Time
	state     pb.FollowState
	subs      map[chan *pb.Envelope]struct{}
	lockCount uint64
	follow    bool // EnableFollow: Steer drives the robot
	drive     Drive
	steeredAt time.Time
	frontM    float64 // front VL53L0X, m (0 = no reading)
	frontAt   time.Time
}

// FrontRange takes the front distance sensor's reading from the telemetry
// (mm, 0 = no reading, frontMaxMm = nothing in range).
func (h *Hub) FrontRange(mm uint32) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.frontM, h.frontAt = 0, h.now()
	if mm > 0 && mm < frontMaxMm {
		h.frontM = float64(mm) / 1000
	}
}

// EnableFollow lets Steer drive the robot towards the locked target.
func (h *Hub) EnableFollow(d Drive) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.follow, h.drive = true, d
}

// Steer takes an app Command on its way to the ESP32. While a target is
// locked and the app is in walk mode with its sticks at rest, the speeds
// become the ones that follow the target (zero when it is out of view).
// A stick or STOP cancels following, and the Command goes out as the pilot
// sent it.
func (h *Hub) Steer(c *pb.Command) *pb.Command {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.track == 0 {
		return c
	}
	if c.Estop || math.Abs(float64(c.Vx)) > TakeOver || math.Abs(float64(c.Vy)) > TakeOver ||
		math.Abs(float64(c.YawRate)) > TakeOver {
		h.log.Info("pilot took over: follow cancelled", "track", h.track)
		h.track, h.lastSeen = 0, nil
		h.refresh()
		h.publishLocked(&pb.Envelope{Payload: &pb.Envelope_FollowStatus{FollowStatus: h.statusLocked()}})
		return c
	}
	if !h.follow || c.Mode != pb.Mode_MODE_WALK {
		return c // locked only: sitting, posing, or following not enabled
	}
	out := proto.CloneOf(c)
	out.Vx, out.Vy, out.YawRate = 0, 0, 0
	if h.state == pb.FollowState_FOLLOW_STATE_LOCKED && h.lastSeen != nil {
		bearing := float64(h.lastSeen.BearingDeg)
		front := 0.0
		if h.now().Sub(h.frontAt) < frontFresh {
			front = h.frontM
		}
		vx, yaw := h.drive.Steer(bearing, Fuse(bearing, float64(h.lastSeen.DistanceM), front))
		out.Vx, out.YawRate = float32(vx), float32(yaw)
	}
	was := h.following()
	h.steeredAt = h.now()
	if !was {
		h.publishLocked(&pb.Envelope{Payload: &pb.Envelope_FollowStatus{FollowStatus: h.statusLocked()}})
	}
	return out
}

func (h *Hub) following() bool {
	return h.track != 0 && h.state == pb.FollowState_FOLLOW_STATE_LOCKED && h.now().Sub(h.steeredAt) < steerFresh
}

// New makes an idle hub.
func New(log *slog.Logger) *Hub {
	return &Hub{log: log, now: time.Now, state: pb.FollowState_FOLLOW_STATE_IDLE,
		subs: map[chan *pb.Envelope]struct{}{}}
}

// Run listens for hexvision on addr (e.g. 127.0.0.1:47300) until ctx ends.
func (h *Hub) Run(ctx context.Context, addr string) error {
	conn, err := net.ListenPacket("udp", addr)
	if err != nil {
		return err
	}
	go func() { <-ctx.Done(); _ = conn.Close() }()
	go func() { // targets going stale and lost ones released, without frames
		t := time.NewTicker(100 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				h.Tick()
			}
		}
	}()
	buf := make([]byte, 2048)
	for {
		n, _, err := conn.ReadFrom(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		var env pb.Envelope
		if proto.Unmarshal(buf[:n], &env) != nil || env.GetTargets() == nil {
			continue
		}
		h.Update(env.GetTargets())
	}
}

// Update takes a frame's targets and tells the subscribers.
func (h *Hub) Update(t *pb.Targets) {
	h.mu.Lock()
	h.latest, h.latestAt = t, h.now()
	h.refresh()
	status := h.statusLocked()
	h.publishLocked(&pb.Envelope{Payload: &pb.Envelope_Targets{Targets: t}})
	h.publishLocked(&pb.Envelope{Payload: &pb.Envelope_FollowStatus{FollowStatus: status}})
	h.mu.Unlock()
}

// Tick lets time pass with no frame: stale targets, lost ones released.
func (h *Hub) Tick() {
	h.mu.Lock()
	defer h.mu.Unlock()
	was := h.state
	if h.latest != nil && h.now().Sub(h.latestAt) > StaleAfter {
		h.latest = nil
		h.publishLocked(&pb.Envelope{Payload: &pb.Envelope_Targets{Targets: &pb.Targets{}}})
	}
	h.refresh()
	if h.state != was {
		h.publishLocked(&pb.Envelope{Payload: &pb.Envelope_FollowStatus{FollowStatus: h.statusLocked()}})
	}
}

// Follow locks onto a target in view (0: stop following). It returns the
// new status; a target not in view is not locked.
func (h *Hub) Follow(track uint32) *pb.FollowStatus {
	h.mu.Lock()
	defer h.mu.Unlock()
	if track == 0 {
		h.track, h.lastSeen = 0, nil
	} else if t := h.find(track); t != nil {
		h.track, h.lastSeen, h.seenAt = track, t, h.now()
		h.lockCount++
		h.log.Info("follow target locked", "track", track)
	}
	h.refresh()
	st := h.statusLocked()
	h.publishLocked(&pb.Envelope{Payload: &pb.Envelope_FollowStatus{FollowStatus: st}})
	return st
}

// Status is the follow state now.
func (h *Hub) Status() *pb.FollowStatus {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.statusLocked()
}

// Locks counts the locks so far (a new one makes the eye react).
func (h *Hub) Locks() uint64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.lockCount
}

// Subscribe streams Targets and FollowStatus envelopes. A slow reader
// misses some: only the newest matter.
func (h *Hub) Subscribe() (<-chan *pb.Envelope, func()) {
	ch := make(chan *pb.Envelope, 8)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	return ch, func() {
		h.mu.Lock()
		delete(h.subs, ch)
		h.mu.Unlock()
	}
}

func (h *Hub) publishLocked(env *pb.Envelope) {
	for ch := range h.subs {
		select {
		case ch <- env:
		default:
		}
	}
}

func (h *Hub) find(track uint32) *pb.Target {
	if h.latest == nil {
		return nil
	}
	for _, t := range h.latest.Targets {
		if t.TrackId == track {
			return t
		}
	}
	return nil
}

// refresh derives the state from the lock and the latest frame.
func (h *Hub) refresh() {
	switch {
	case h.track == 0:
		h.state = pb.FollowState_FOLLOW_STATE_IDLE
	case h.find(h.track) != nil:
		h.lastSeen, h.seenAt = h.find(h.track), h.now()
		h.state = pb.FollowState_FOLLOW_STATE_LOCKED
	case h.now().Sub(h.seenAt) > ReleaseAfter:
		h.log.Info("follow target released", "track", h.track)
		h.track, h.lastSeen = 0, nil
		h.state = pb.FollowState_FOLLOW_STATE_IDLE
	default:
		h.state = pb.FollowState_FOLLOW_STATE_LOST
	}
}

func (h *Hub) statusLocked() *pb.FollowStatus {
	st := &pb.FollowStatus{State: h.state, TrackId: h.track}
	if h.following() {
		st.State = pb.FollowState_FOLLOW_STATE_FOLLOWING
	}
	if h.lastSeen != nil {
		st.BearingDeg, st.DistanceM = h.lastSeen.BearingDeg, h.lastSeen.DistanceM
	}
	if h.state == pb.FollowState_FOLLOW_STATE_LOST {
		st.LostMs = uint32(h.now().Sub(h.seenAt).Milliseconds())
	}
	return st
}
