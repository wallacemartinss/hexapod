package shutdown

import (
	"context"
	"io"
	"log/slog"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

var quiet = slog.New(slog.NewTextHandler(io.Discard, nil))

func feed(ch chan<- *pb.Telemetry, state pb.State, faults uint32, d time.Duration) {
	for end := time.Now().Add(d); time.Now().Before(end); {
		ch <- &pb.Telemetry{State: state, FaultFlags: faults}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestPowersOffOnlyAfterSustainedCriticalBattery(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := make(chan *pb.Telemetry)
	var runs atomic.Int32
	done := make(chan struct{})
	go func() {
		Watch(ctx, ch, 200*time.Millisecond, []string{"poweroff"}, func(context.Context, []string) error {
			runs.Add(1)
			return nil
		}, quiet)
		close(done)
	}()

	crit := uint32(pb.Fault_FAULT_BATTERY_CRITICAL)
	feed(ch, pb.State_STATE_LOW_BATTERY, crit, 120*time.Millisecond) // too short
	feed(ch, pb.State_STATE_NORMAL, 0, 50*time.Millisecond)          // recovered
	feed(ch, pb.State_STATE_NORMAL, crit, 300*time.Millisecond)      // not seated
	if runs.Load() != 0 {
		t.Fatal("powered off too early")
	}
	go feed(ch, pb.State_STATE_LOW_BATTERY, crit, time.Second)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("no power-off")
	}
	if runs.Load() != 1 {
		t.Fatalf("runs = %d", runs.Load())
	}
}
