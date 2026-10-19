// Package vision receives follow-me targets from hexvision (UDP, one
// Envelope per frame) and keeps the pilot's choice: which target is
// followed, and whether it is in view.
//
// Nothing here moves the robot. Following (F2) will turn the locked
// target into Commands, still under the ESP32 failsafe.
package vision

import (
	"context"
	"log/slog"
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
	if h.lastSeen != nil {
		st.BearingDeg, st.DistanceM = h.lastSeen.BearingDeg, h.lastSeen.DistanceM
	}
	if h.state == pb.FollowState_FOLLOW_STATE_LOST {
		st.LostMs = uint32(h.now().Sub(h.seenAt).Milliseconds())
	}
	return st
}
