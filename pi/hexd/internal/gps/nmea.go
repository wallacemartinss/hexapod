// Package gps reads a NMEA GPS (u-blox NEO-6M on the Pi's UART) into a
// hexapod.v1.Position.
package gps

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

const knotsToMps = 0.514444

var errChecksum = errors.New("nmea: bad checksum")

// sentence splits "$GPRMC,...*hh" into its type ("RMC", talker dropped)
// and fields, checking the checksum.
func sentence(line string) (kind string, fields []string, err error) {
	line = strings.TrimSpace(line)
	if !strings.HasPrefix(line, "$") {
		return "", nil, fmt.Errorf("nmea: no '$' in %q", line)
	}
	body, sum, ok := strings.Cut(line[1:], "*")
	if !ok || len(sum) != 2 {
		return "", nil, fmt.Errorf("nmea: no checksum in %q", line)
	}
	want, err := strconv.ParseUint(sum, 16, 8)
	if err != nil {
		return "", nil, errChecksum
	}
	var got byte
	for i := 0; i < len(body); i++ {
		got ^= body[i]
	}
	if got != byte(want) {
		return "", nil, errChecksum
	}
	fields = strings.Split(body, ",")
	if len(fields[0]) != 5 { // GPRMC, GNGGA, ...
		return "", nil, fmt.Errorf("nmea: odd address %q", fields[0])
	}
	return fields[0][2:], fields[1:], nil
}

// Fix accumulates the sentences of one GPS cycle into a Position.
type Fix struct {
	pos *pb.Position
}

// Position is a copy of what is known so far.
func (f *Fix) Position() *pb.Position {
	if f.pos == nil {
		return &pb.Position{}
	}
	return proto.CloneOf(f.pos)
}

// Feed applies one NMEA line. Lines of other kinds are ignored; corrupted
// ones return an error and change nothing.
func (f *Fix) Feed(line string) error {
	kind, v, err := sentence(line)
	if err != nil {
		return err
	}
	if f.pos == nil {
		f.pos = &pb.Position{}
	}
	switch kind {
	case "RMC": // time, status, lat, N/S, lon, E/W, speed kn, course, date, ...
		if len(v) < 9 {
			return fmt.Errorf("nmea: short RMC")
		}
		f.pos.Fix = v[1] == "A"
		if f.pos.Fix {
			f.pos.LatitudeDeg = coordinate(v[2], v[3])
			f.pos.LongitudeDeg = coordinate(v[4], v[5])
			f.pos.SpeedMps = float32(number(v[6]) * knotsToMps)
			f.pos.CourseDeg = float32(number(v[7]))
		}
		if t, ok := utc(v[0], v[8]); ok {
			f.pos.UtcMs = uint64(t.UnixMilli())
		}
	case "GGA": // time, lat, N/S, lon, E/W, quality, satellites, hdop, altitude, M, ...
		if len(v) < 9 {
			return fmt.Errorf("nmea: short GGA")
		}
		f.pos.SatellitesUsed = uint32(number(v[6]))
		f.pos.Hdop = float32(number(v[7]))
		f.pos.AltitudeM = float32(number(v[8]))
	case "GSV": // messages, index, satellites in view, ...
		if len(v) >= 3 {
			f.pos.SatellitesInView = uint32(number(v[2]))
		}
	}
	return nil
}

// coordinate turns "ddmm.mmmm" (or "dddmm.mmmm") and a hemisphere into
// signed degrees.
func coordinate(value, hemisphere string) float64 {
	dot := strings.IndexByte(value, '.')
	if dot < 2 {
		return 0
	}
	deg := number(value[:dot-2])
	minutes := number(value[dot-2:])
	d := deg + minutes/60
	if hemisphere == "S" || hemisphere == "W" {
		d = -d
	}
	return d
}

// utc combines RMC "hhmmss.ss" and "ddmmyy".
func utc(clock, date string) (time.Time, bool) {
	if len(clock) < 6 || len(date) != 6 {
		return time.Time{}, false
	}
	t, err := time.Parse("020106150405", date+clock[:6])
	if err != nil {
		return time.Time{}, false
	}
	if frac := clock[6:]; strings.HasPrefix(frac, ".") {
		t = t.Add(time.Duration(number("0"+frac) * float64(time.Second)))
	}
	return t, true
}

func number(s string) float64 {
	v, _ := strconv.ParseFloat(s, 64)
	return v
}
