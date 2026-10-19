package gps

import (
	"bufio"
	"context"
	"io"
	"log/slog"
	"math"
	"net"
	"strings"
	"sync"
	"time"

	"go.bug.st/serial"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

// Reader keeps the latest Position from a GPS. Safe for concurrent use.
type Reader struct {
	mu     sync.Mutex
	fix    Fix
	lastRx time.Time
}

// Latest is the newest Position and whether the GPS spoke within maxAge
// (false: no GPS, or it went quiet).
func (r *Reader) Latest(maxAge time.Duration) (*pb.Position, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.fix.Position(), !r.lastRx.IsZero() && time.Since(r.lastRx) < maxAge
}

func (r *Reader) feed(line string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.fix.Feed(line) == nil {
		r.lastRx = time.Now()
	}
}

// Serial opens a NMEA serial port, or a TCP stream for "tcp://host:port"
// (hexsim -gps).
func Serial(device string, baud int) func() (io.ReadCloser, error) {
	return func() (io.ReadCloser, error) {
		if addr, ok := strings.CutPrefix(device, "tcp://"); ok {
			return net.DialTimeout("tcp", addr, 2*time.Second)
		}
		return serial.Open(device, &serial.Mode{BaudRate: baud})
	}
}

// Run reads open() line by line until ctx ends, reopening after errors. A
// missing GPS is logged once.
func (r *Reader) Run(ctx context.Context, open func() (io.ReadCloser, error), log *slog.Logger) {
	failing := false
	for ctx.Err() == nil {
		port, err := open()
		if err != nil {
			if !failing {
				log.Warn("GPS unavailable, retrying", "err", err)
				failing = true
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(10 * time.Second):
			}
			continue
		}
		if failing {
			log.Info("GPS back")
			failing = false
		}
		stop := context.AfterFunc(ctx, func() { _ = port.Close() })
		lines := bufio.NewScanner(port)
		for lines.Scan() {
			r.feed(lines.Text())
		}
		stop()
		_ = port.Close()
		select { // a port that keeps failing must not spin
		case <-ctx.Done():
		case <-time.After(time.Second):
		}
	}
}

// Simulate feeds the Reader a slow walk around a point, for app
// development without the module (hexd.yaml gps.simulate).
func (r *Reader) Simulate(ctx context.Context, lat, lon float64) {
	start := time.Now()
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		t := time.Since(start).Seconds()
		r.mu.Lock()
		r.fix.pos = &pb.Position{
			Fix:              t > 5, // a few seconds "searching" first
			LatitudeDeg:      lat + 0.0002*math.Sin(t/60),
			LongitudeDeg:     lon + 0.0002*math.Cos(t/60),
			AltitudeM:        760,
			SpeedMps:         0.3,
			CourseDeg:        float32(math.Mod(t*6, 360)),
			SatellitesUsed:   8,
			SatellitesInView: 11,
			Hdop:             1.1,
			UtcMs:            uint64(time.Now().UnixMilli()),
		}
		r.lastRx = time.Now()
		r.mu.Unlock()
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
