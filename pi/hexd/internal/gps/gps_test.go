package gps

import (
	"context"
	"io"
	"log/slog"
	"math"
	"strings"
	"testing"
	"time"
)

// Lines captured from the bench GY-NEO6MV2 indoors (no fix), plus a
// textbook fixed cycle.
const (
	indoorRMC = "$GPRMC,230005.00,V,,,,,,,181026,,,N*75"
	indoorGGA = "$GPGGA,230005.00,,,,,0,00,99.99,,,,,,*62"
	indoorGSV = "$GPGSV,1,1,01,02,,,32*7B"
	fixedRMC  = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A"
	fixedGGA  = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47"
)

func TestIndoorNoFixButTime(t *testing.T) {
	var f Fix
	for _, l := range []string{indoorRMC, indoorGGA, indoorGSV} {
		if err := f.Feed(l); err != nil {
			t.Fatalf("%s: %v", l, err)
		}
	}
	p := f.Position()
	if p.Fix || p.LatitudeDeg != 0 {
		t.Fatalf("no fix expected: %v", p)
	}
	if p.SatellitesInView != 1 || p.SatellitesUsed != 0 {
		t.Fatalf("satellites: %v", p)
	}
	want := time.Date(2026, 10, 18, 23, 0, 5, 0, time.UTC)
	if got := time.UnixMilli(int64(p.UtcMs)).UTC(); !got.Equal(want) {
		t.Fatalf("time %v, want %v", got, want)
	}
}

func TestFixedCycle(t *testing.T) {
	var f Fix
	for _, l := range []string{fixedRMC, fixedGGA} {
		if err := f.Feed(l); err != nil {
			t.Fatalf("%s: %v", l, err)
		}
	}
	p := f.Position()
	near := func(got, want float64) bool { return math.Abs(got-want) < 1e-6 }
	if !p.Fix || !near(p.LatitudeDeg, 48+7.038/60) || !near(p.LongitudeDeg, 11+31.0/60) {
		t.Fatalf("position: %v", p)
	}
	if p.SatellitesUsed != 8 || math.Abs(float64(p.Hdop)-0.9) > 1e-6 || math.Abs(float64(p.AltitudeM)-545.4) > 1e-3 {
		t.Fatalf("GGA fields: %v", p)
	}
	if math.Abs(float64(p.SpeedMps)-22.4*knotsToMps) > 1e-3 {
		t.Fatalf("speed %v", p.SpeedMps)
	}
}

func TestSouthWestIsNegative(t *testing.T) {
	if got := coordinate("2333.0000", "S"); math.Abs(got+23.55) > 1e-9 {
		t.Fatalf("S: %v", got)
	}
	if got := coordinate("04638.0000", "W"); math.Abs(got+46.6333333333) > 1e-9 {
		t.Fatalf("W: %v", got)
	}
}

func TestCorruptedLineChangesNothing(t *testing.T) {
	var f Fix
	_ = f.Feed(fixedRMC)
	bad := strings.Replace(fixedRMC, "4807", "4907", 1) // checksum no longer matches
	if err := f.Feed(bad); err == nil {
		t.Fatal("bad checksum accepted")
	}
	if p := f.Position(); math.Abs(p.LatitudeDeg-(48+7.038/60)) > 1e-6 {
		t.Fatalf("corrupted line changed the position: %v", p)
	}
	for _, junk := range []string{"", "garbage", "$GPRMC,1,2", "$X*00"} {
		if f.Feed(junk) == nil {
			t.Errorf("%q accepted", junk)
		}
	}
}

func TestReaderLatestAndMissingGPS(t *testing.T) {
	var r Reader
	if _, ok := r.Latest(3 * time.Second); ok {
		t.Fatal("no GPS yet must not be fresh")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	open := func() (io.ReadCloser, error) {
		return io.NopCloser(strings.NewReader(indoorRMC + "\r\n" + indoorGSV + "\r\n")), nil
	}
	go r.Run(ctx, open, slog.New(slog.NewTextHandler(io.Discard, nil)))
	deadline := time.Now().Add(2 * time.Second)
	for {
		if p, ok := r.Latest(3 * time.Second); ok && p.SatellitesInView == 1 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("reader never got the lines")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
