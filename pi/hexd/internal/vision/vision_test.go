package vision

import (
	"context"
	"io"
	"log/slog"
	"net"
	"testing"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"google.golang.org/protobuf/proto"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time      { return c.t }
func (c *clock) add(d time.Duration) { c.t = c.t.Add(d) }
func frame(ids ...uint32) *pb.Targets {
	t := &pb.Targets{}
	for _, id := range ids {
		t.Targets = append(t.Targets, &pb.Target{TrackId: id, BearingDeg: float32(id), DistanceM: 1})
	}
	return t
}

func newHub() (*Hub, *clock) {
	c := &clock{t: time.Unix(1000, 0)}
	h := New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	h.now = c.now
	return h, c
}

func TestLockOnlyTargetsInView(t *testing.T) {
	h, _ := newHub()
	h.Update(frame(3, 5))
	if st := h.Follow(9); st.State != pb.FollowState_FOLLOW_STATE_IDLE {
		t.Fatalf("locked a target not in view: %v", st)
	}
	st := h.Follow(5)
	if st.State != pb.FollowState_FOLLOW_STATE_LOCKED || st.TrackId != 5 || st.BearingDeg != 5 {
		t.Fatalf("lock: %v", st)
	}
	if h.Locks() != 1 {
		t.Fatalf("locks = %d", h.Locks())
	}
	if st := h.Follow(0); st.State != pb.FollowState_FOLLOW_STATE_IDLE || st.TrackId != 0 {
		t.Fatalf("cancel: %v", st)
	}
}

func TestLostThenBackThenReleased(t *testing.T) {
	h, c := newHub()
	h.Update(frame(2))
	h.Follow(2)
	c.add(100 * time.Millisecond)
	h.Update(frame(4)) // another marker only
	st := h.Status()
	if st.State != pb.FollowState_FOLLOW_STATE_LOST || st.BearingDeg != 2 {
		t.Fatalf("not lost, or forgot where: %v", st)
	}
	c.add(time.Second)
	h.Update(frame(2, 4))
	if h.Status().State != pb.FollowState_FOLLOW_STATE_LOCKED {
		t.Fatal("did not take it back")
	}
	h.Update(frame())
	c.add(ReleaseAfter + time.Millisecond)
	h.Tick()
	if st := h.Status(); st.State != pb.FollowState_FOLLOW_STATE_IDLE || st.TrackId != 0 {
		t.Fatalf("not released: %v", st)
	}
}

func TestStaleFramesMeanNothingInView(t *testing.T) {
	h, c := newHub()
	h.Update(frame(1))
	h.Follow(1)
	ch, stop := h.Subscribe()
	defer stop()
	c.add(StaleAfter + time.Millisecond) // hexvision went quiet
	h.Tick()
	if h.Status().State != pb.FollowState_FOLLOW_STATE_LOST {
		t.Fatal("still locked with no frames")
	}
	got := map[string]bool{}
	for len(ch) > 0 {
		e := <-ch
		if tg := e.GetTargets(); tg != nil && len(tg.Targets) == 0 {
			got["empty targets"] = true
		}
		if e.GetFollowStatus() != nil {
			got["status"] = true
		}
	}
	if !got["empty targets"] || !got["status"] {
		t.Fatalf("subscribers not told: %v", got)
	}
}

func TestRunReceivesUDP(t *testing.T) {
	h, _ := newHub()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := pc.LocalAddr().String()
	_ = pc.Close()
	go func() { _ = h.Run(ctx, addr) }()
	ch, stop := h.Subscribe()
	defer stop()
	b, _ := proto.Marshal(&pb.Envelope{Payload: &pb.Envelope_Targets{Targets: frame(7)}})
	conn, _ := net.Dial("udp", addr)
	defer conn.Close()
	deadline := time.After(2 * time.Second)
	for {
		_, _ = conn.Write(b)
		select {
		case e := <-ch:
			if tg := e.GetTargets(); tg != nil && len(tg.Targets) == 1 {
				return
			}
		case <-time.After(50 * time.Millisecond):
		case <-deadline:
			t.Fatal("no targets over UDP")
		}
	}
}
