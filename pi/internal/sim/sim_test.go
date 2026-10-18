package sim

import (
	"context"
	"net"
	"testing"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"github.com/wallacemartinss/hexapod/pi/internal/link"
	"google.golang.org/protobuf/proto"
)

// client is the hexd side of a pipe to the simulator.
type client struct {
	t    *testing.T
	conn net.Conn
	in   chan *pb.Envelope
	seq  uint32
}

func dial(t *testing.T, s *Sim) (*client, context.CancelFunc) {
	a, b := net.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	go func() { _ = s.Serve(ctx, b) }()
	c := &client{t: t, conn: a, in: make(chan *pb.Envelope, 256)}
	go func() {
		var dec link.Decoder
		buf := make([]byte, 256)
		for {
			n, err := a.Read(buf)
			if err != nil {
				close(c.in)
				return
			}
			for _, x := range buf[:n] {
				if p, err := dec.Push(x); err == nil && p != nil {
					var env pb.Envelope
					if proto.Unmarshal(p, &env) == nil {
						c.in <- &env
					}
				}
			}
		}
	}()
	return c, func() { cancel(); a.Close(); b.Close() }
}

func (c *client) send(cmd *pb.Command) {
	c.seq++
	cmd.Seq = c.seq
	frame, _ := link.EncodeEnvelope(&pb.Envelope{Payload: &pb.Envelope_Command{Command: cmd}})
	if _, err := c.conn.Write(frame); err != nil {
		c.t.Fatal(err)
	}
}

// waitState reads telemetry until `want` shows up or the timeout expires.
func (c *client) waitState(want pb.State, timeout time.Duration) *pb.Telemetry {
	c.t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case env, ok := <-c.in:
			if !ok {
				c.t.Fatal("connection closed")
			}
			if tel := env.GetTelemetry(); tel != nil && tel.State == want {
				return tel
			}
		case <-deadline:
			c.t.Fatalf("no %v within %v", want, timeout)
		}
	}
}

func TestServeHelloAndFailsafe(t *testing.T) {
	s := New(Options{BootNoise: true, FirmwareVersion: "sim-test"})
	c, done := dial(t, s)
	defer done()

	first := <-c.in // boot noise is skipped by the decoder
	if h := first.GetHello(); h == nil || h.FirmwareVersion != "sim-test" || h.ProtocolVersion != 1 {
		t.Fatalf("first message: %v", first)
	}
	c.waitState(pb.State_STATE_RELAXED, time.Second)

	c.send(&pb.Command{Mode: pb.Mode_MODE_STAND})
	tel := c.waitState(pb.State_STATE_NORMAL, time.Second)
	if tel.LastCommandSeq != 1 || len(tel.JointAnglesDeg) != 18 || len(tel.DistancesMm) != 4 {
		t.Fatalf("telemetry: %v", tel)
	}
	c.waitState(pb.State_STATE_STOPPING, time.Second) // we went silent
	c.waitState(pb.State_STATE_SAFE_SIT, time.Second)
}

func TestStateSurvivesReconnect(t *testing.T) {
	s := New(Options{})
	c, done := dial(t, s)
	for range 5 {
		c.send(&pb.Command{Mode: pb.Mode_MODE_STAND})
	}
	c.waitState(pb.State_STATE_NORMAL, time.Second)
	done()

	c2, done2 := dial(t, s) // hexd restarted: same board, same last seq
	defer done2()
	tel := c2.waitState(pb.State_STATE_SAFE_SIT, 2*time.Second)
	if tel.LastCommandSeq != 5 {
		t.Fatalf("last_command_seq %d, want 5", tel.LastCommandSeq)
	}
}
