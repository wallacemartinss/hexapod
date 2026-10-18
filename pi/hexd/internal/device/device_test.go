package device

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"github.com/wallacemartinss/hexapod/pi/internal/sim"
)

var quiet = slog.New(slog.NewTextHandler(io.Discard, nil))

// simDialer connects to s through an in-process pipe; each dial is a new
// "serial open" on the same (still powered) board.
func simDialer(ctx context.Context, s *sim.Sim) Dialer {
	return func(context.Context) (io.ReadWriteCloser, error) {
		a, b := net.Pipe()
		go func() { _ = s.Serve(ctx, b); b.Close() }()
		return a, nil
	}
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timeout waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func start(t *testing.T, s *sim.Sim, dial Dialer) (*Device, context.CancelFunc) {
	ctx, cancel := context.WithCancel(context.Background())
	if dial == nil {
		dial = simDialer(ctx, s)
	}
	d := New(Options{Dial: dial, HexdVersion: "test", Logger: quiet, SilenceLimit: 400 * time.Millisecond})
	go d.Run(ctx)
	return d, cancel
}

func TestConnectHelloTelemetry(t *testing.T) {
	s := sim.New(sim.Options{FirmwareVersion: "fw-1", BootNoise: true})
	d, stop := start(t, s, nil)
	defer stop()

	waitFor(t, "hello and telemetry", func() bool {
		snap := d.Snapshot()
		return snap.Connected && snap.Hello != nil && snap.Telemetry != nil
	})
	if got := d.Snapshot().Hello.FirmwareVersion; got != "fw-1" {
		t.Fatalf("firmware %q", got)
	}
}

func TestCommandsWaitForSeqAndDriveTheBoard(t *testing.T) {
	s := sim.New(sim.Options{})
	d, stop := start(t, s, nil)
	defer stop()

	waitFor(t, "seq known", func() bool { return d.SendCommand(&pb.Command{}) == nil })
	if err := d.SendCommand(&pb.Command{Mode: pb.Mode_MODE_STAND}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "NORMAL", func() bool { return s.State() == pb.State_STATE_NORMAL })
}

// A restarted hexd must continue the ESP32's seq, not start again at 1.
func TestRestartedHexdResumesSeq(t *testing.T) {
	s := sim.New(sim.Options{})
	d1, stop1 := start(t, s, nil)
	waitFor(t, "seq known", func() bool { return d1.SendCommand(&pb.Command{}) == nil })
	for range 9 {
		if err := d1.SendCommand(&pb.Command{}); err != nil {
			t.Fatal(err)
		}
	}
	waitFor(t, "seq 10 accepted", func() bool {
		tel := d1.Snapshot().Telemetry
		return tel != nil && tel.LastCommandSeq == 10
	})
	stop1()

	d2, stop2 := start(t, s, nil)
	defer stop2()
	waitFor(t, "seq known", func() bool {
		return d2.SendCommand(&pb.Command{Mode: pb.Mode_MODE_STAND}) == nil
	})
	waitFor(t, "command accepted after restart", func() bool {
		tel := d2.Snapshot().Telemetry
		return tel != nil && tel.LastCommandSeq == 11
	})
}

func TestReconnectsAfterFailuresAndSilence(t *testing.T) {
	s := sim.New(sim.Options{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var dials atomic.Int32
	good := simDialer(ctx, s)
	dial := func(c context.Context) (io.ReadWriteCloser, error) {
		switch dials.Add(1) {
		case 1, 2:
			return nil, errors.New("no such device") // ESP32 unplugged
		case 3:
			a, _ := net.Pipe() // opens, but never says anything
			return a, nil
		default:
			return good(c)
		}
	}
	d, stop := start(t, s, dial)
	defer stop()
	waitFor(t, "telemetry after retries", func() bool { return d.Snapshot().Telemetry != nil })
	if n := dials.Load(); n < 4 {
		t.Fatalf("dials = %d, want >= 4", n)
	}
	if d.Snapshot().Reconnects < 1 {
		t.Fatal("silent connection was not dropped")
	}
}

func TestSubscribe(t *testing.T) {
	s := sim.New(sim.Options{})
	d, stop := start(t, s, nil)
	defer stop()
	ch, cancel := d.Subscribe()
	defer cancel()
	select {
	case tel := <-ch:
		if tel.State != pb.State_STATE_RELAXED {
			t.Fatalf("state %v", tel.State)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no telemetry")
	}
}

func TestNotReadyWithoutConnection(t *testing.T) {
	d := New(Options{Logger: quiet})
	if err := d.SendCommand(&pb.Command{}); !errors.Is(err, ErrNotReady) {
		t.Fatalf("err = %v", err)
	}
}
