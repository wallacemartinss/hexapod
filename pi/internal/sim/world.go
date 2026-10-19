package sim

import (
	"context"
	"fmt"
	"io"
	"math"
	"time"
)

// The robot's place in the world, for GPS navigation without hardware: it
// walks at the firmware's speeds, the compass reads its heading (magnetic,
// with noise) and a NEO-6M-like GPS reads its position (with the slow,
// wandering error of a real one).

// Firmware speeds at Command = 1 (config.h kMaxSpeedMmS, kMaxYawRateDegS).
const (
	maxSpeedMps   = 0.08
	maxYawRateDeg = 20.0
	earthRadiusM  = 6371000.0
	gpsNoiseCorr  = 0.98 // per second: the error wanders, it does not jump
)

// WorldOptions place the simulated robot.
type WorldOptions struct {
	Latitude, Longitude float64 // start, WGS84
	HeadingDeg          float64 // start, true north, clockwise
	// DeclinationDeg: true = magnetic + declination (-21 around São Paulo).
	DeclinationDeg float64
	GPSNoiseM      float64 // standard deviation of the GPS error, m
	// SpeedScale speeds the walk up for demos (1 = the real robot).
	SpeedScale float64
}

type world struct {
	opt          WorldOptions
	east, north  float64 // m from the start
	heading      float64 // true, clockwise
	gyroStart    float64 // game rotation vector yaw at heading 0: an arbitrary frame
	noiseE       float64
	noiseN       float64
	speed, track float64 // over ground, m/s and deg
}

func newWorld(opt WorldOptions) *world {
	if opt.SpeedScale == 0 {
		opt.SpeedScale = 1
	}
	return &world{opt: opt, heading: opt.HeadingDeg, gyroStart: 37}
}

// SetWorld places the robot (default: São Paulo, facing north, no noise).
func (s *Sim) SetWorld(opt WorldOptions) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.world = newWorld(opt)
}

// walk moves the robot by the accepted speeds for dt seconds.
func (w *world) walk(vx, vy, yawRate, dt float64) {
	k := w.opt.SpeedScale
	w.heading = math.Mod(w.heading-yawRate*maxYawRateDeg*k*dt+360, 360) // + yaw = left
	h := w.heading * math.Pi / 180
	fwd, left := vx*maxSpeedMps*k, vy*maxSpeedMps*k
	ve := fwd*math.Sin(h) - left*math.Cos(h)
	vn := fwd*math.Cos(h) + left*math.Sin(h)
	w.east += ve * dt
	w.north += vn * dt
	w.speed = math.Hypot(ve, vn)
	w.track = math.Mod(math.Atan2(ve, vn)*180/math.Pi+360, 360)
}

// gyroYaw is what the game rotation vector reads: + = left, its own zero.
func (w *world) gyroYaw() float64 {
	return math.Remainder(w.gyroStart-w.heading, 360)
}

func (w *world) magnetic() float64 {
	return math.Mod(w.heading-w.opt.DeclinationDeg+720, 360)
}

// fix is where the GPS thinks the robot is; call once a second.
func (s *Sim) fix() (lat, lon float64) {
	w := s.world
	a := w.opt.GPSNoiseM * math.Sqrt(1-gpsNoiseCorr*gpsNoiseCorr)
	w.noiseE = gpsNoiseCorr*w.noiseE + a*s.rng.NormFloat64()
	w.noiseN = gpsNoiseCorr*w.noiseN + a*s.rng.NormFloat64()
	lat0 := w.opt.Latitude * math.Pi / 180
	lat = w.opt.Latitude + (w.north+w.noiseN)/earthRadiusM*180/math.Pi
	lon = w.opt.Longitude + (w.east+w.noiseE)/(earthRadiusM*math.Cos(lat0))*180/math.Pi
	return lat, lon
}

// ServeGPS writes NMEA (GGA + RMC) once a second to wr, like the NEO-6M on
// the Pi's UART, until ctx ends or the write fails.
func (s *Sim) ServeGPS(ctx context.Context, wr io.Writer) error {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
		}
		s.mu.Lock()
		lat, lon := s.fix()
		speed, track := s.world.speed, s.world.track
		s.mu.Unlock()
		now := s.opt.Now().UTC()
		hms := now.Format("150405.00")
		la, ns := nmeaAngle(lat, 2), "N"
		if lat < 0 {
			ns = "S"
		}
		lo, ew := nmeaAngle(lon, 3), "E"
		if lon < 0 {
			ew = "W"
		}
		lines := []string{
			fmt.Sprintf("GPGGA,%s,%s,%s,%s,%s,1,08,1.1,760.0,M,-5.0,M,,", hms, la, ns, lo, ew),
			fmt.Sprintf("GPRMC,%s,A,%s,%s,%s,%s,%.2f,%.1f,%s,,,A", hms, la, ns, lo, ew,
				speed/0.514444, track, now.Format("020106")),
		}
		for _, l := range lines {
			if _, err := fmt.Fprintf(wr, "$%s*%02X\r\n", l, nmeaSum(l)); err != nil {
				return err
			}
		}
	}
}

// nmeaAngle is ddmm.mmmmm (or dddmm.mmmmm), unsigned.
func nmeaAngle(deg float64, width int) string {
	deg = math.Abs(deg)
	d := math.Floor(deg)
	return fmt.Sprintf("%0*d%08.5f", width, int(d), (deg-d)*60)
}

func nmeaSum(body string) byte {
	var sum byte
	for i := 0; i < len(body); i++ {
		sum ^= body[i]
	}
	return sum
}
