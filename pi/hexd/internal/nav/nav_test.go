package nav

import (
	"io"
	"log/slog"
	"math"
	"math/rand/v2"
	"path/filepath"
	"testing"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

var start = Point{-23.5505, -46.6333}

// world is a robot walking on a plane, as the firmware would move it
// (8 cm/s, 20 deg/s at full stick), with a compass bent by declination
// and a GPS that wanders a little.
type world struct {
	t         time.Time
	east      float64
	north     float64
	heading   float64 // true
	decl      float64 // true = magnetic + decl
	gpsNoise  float64
	rng       *rand.Rand
	nE, nN    float64
	utc       uint64
	blocked   bool
	battery   float32
	following bool
	noFix     bool
}

func newWorld() *world {
	return &world{t: time.Unix(1000, 0), rng: rand.New(rand.NewPCG(3, 4)), battery: 12}
}

func (w *world) point() Point {
	lat0 := start.Lat * math.Pi / 180
	return Point{start.Lat + (w.north+w.nN)/earthRadiusM*180/math.Pi,
		start.Lon + (w.east+w.nE)/(earthRadiusM*math.Cos(lat0))*180/math.Pi}
}

func (w *world) inputs() Inputs {
	return Inputs{
		Position: func() (*pb.Position, bool) {
			p := w.point()
			return &pb.Position{Fix: !w.noFix, LatitudeDeg: p.Lat, LongitudeDeg: p.Lon, Hdop: 1, UtcMs: w.utc}, true
		},
		Telemetry: func() *pb.Telemetry {
			var mask uint32
			if w.blocked {
				mask = 1
			}
			return &pb.Telemetry{Orientation: &pb.Quaternion{W: 1}, YawDeg: float32(math.Remainder(50-w.heading, 360)),
				BlockedMask: mask, BatteryVoltageV: w.battery}
		},
		Compass: func() (*pb.Compass, time.Time) {
			return &pb.Compass{HeadingDeg: float32(wrap360(w.heading - w.decl)), AccuracyDeg: 8}, w.t
		},
		Following: func() bool { return w.following },
	}
}

// step: dt of walking at the Command's speeds; the GPS speaks every second.
func (w *world) step(c *pb.Command, dt time.Duration) {
	s := dt.Seconds()
	w.heading = wrap360(w.heading - float64(c.YawRate)*20*s)
	h := w.heading * math.Pi / 180
	fwd, left := float64(c.Vx)*0.08, float64(c.Vy)*0.08
	if w.blocked && fwd > 0 {
		fwd = 0
	}
	w.east += (fwd*math.Sin(h) - left*math.Cos(h)) * s
	w.north += (fwd*math.Cos(h) + left*math.Sin(h)) * s
	before := w.t
	w.t = w.t.Add(dt)
	if w.t.Unix() != before.Unix() {
		w.utc = uint64(w.t.UnixMilli())
		a := w.gpsNoise * math.Sqrt(1-0.98*0.98)
		w.nE = 0.98*w.nE + a*w.rng.NormFloat64()
		w.nN = 0.98*w.nN + a*w.rng.NormFloat64()
	}
}

func newNav(t *testing.T, w *world, cfg Config) *Navigator {
	t.Helper()
	cfg.Drive = true // tests drive; TestDriveOff checks the default
	n := New(cfg, w.inputs(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	n.now = func() time.Time { return w.t }
	return n
}

func walk(vx, yaw float32) *pb.Command {
	return &pb.Command{Mode: pb.Mode_MODE_WALK, Vx: vx, YawRate: yaw}
}

// run drives the loop as hexd would: the app's resting walk Commands at
// 20 Hz through Steer, the navigator's update at 10 Hz.
func run(n *Navigator, w *world, d time.Duration, until func() bool) {
	for end := w.t.Add(d); w.t.Before(end); {
		out := n.Steer(walk(0, 0))
		w.step(out, 50*time.Millisecond)
		if w.t.UnixMilli()%100 == 0 {
			n.Update()
		}
		if until != nil && until() {
			return
		}
	}
}

func at(east, north float64) Point {
	w := &world{east: east, north: north}
	return w.point()
}

func gp(p Point) *pb.GeoPoint { return &pb.GeoPoint{LatitudeDeg: p.Lat, LongitudeDeg: p.Lon} }

func settle(n *Navigator, w *world) {
	for range 60 { // GPS fixes and the compass settle (and home is set)
		w.step(walk(0, 0), 100*time.Millisecond)
		n.Update()
	}
}

func TestGeo(t *testing.T) {
	a, b := at(0, 0), at(30, 40)
	if d := Distance(a, b); math.Abs(d-50) > 0.01 {
		t.Fatalf("distance %.3f, want 50", d)
	}
	if br := Bearing(a, at(-10, 0)); math.Abs(br-270) > 0.01 {
		t.Fatalf("bearing west %.2f", br)
	}
	square := []Point{at(-10, -10), at(10, -10), at(10, 10), at(-10, 10)}
	if !Inside(at(0, 0), square) || Inside(at(11, 0), square) || Inside(at(0, -10.5), square) {
		t.Fatal("inside the square wrong")
	}
}

func TestGoesToAPointAndStops(t *testing.T) {
	w := newWorld()
	w.gpsNoise = 1
	n := newNav(t, w, DefaultConfig())
	settle(n, w)
	goal := at(20, 15) // 25 m, north-east; the robot faces north
	if st := n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_GO_TO, Points: []*pb.GeoPoint{gp(goal)}}); st.Refused != 0 {
		t.Fatalf("refused: %v", st.Refused)
	}
	run(n, w, 15*time.Minute, func() bool { return n.Status().State == pb.NavState_NAV_STATE_ARRIVED })
	if n.Status().State != pb.NavState_NAV_STATE_ARRIVED {
		t.Fatalf("not there after 15 min: %.1f m away, state %v", Distance(w.point(), goal), n.Status().State)
	}
	if d := math.Hypot(w.east-20, w.north-15); d > 5 {
		t.Fatalf("stopped %.1f m from the goal", d)
	}
	// Arrived: the app's Commands go through untouched, at rest.
	if out := n.Steer(walk(0, 0)); out.Vx != 0 || out.YawRate != 0 {
		t.Fatalf("still steering after arriving: %v", out)
	}
}

func TestGPSLearnsAWrongDeclination(t *testing.T) {
	w := newWorld()
	w.decl = -21 // São Paulo; the config says 0
	n := newNav(t, w, DefaultConfig())
	settle(n, w)
	h, _ := n.heading.True(w.t, math.Remainder(50-w.heading, 360))
	if e := math.Abs(wrap180(h - w.heading)); e < 15 {
		t.Fatalf("the compass alone should be off by the declination, is off by %.1f", e)
	}
	goal := at(0, 80) // a long walk north
	n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_GO_TO, Points: []*pb.GeoPoint{gp(goal)}})
	run(n, w, 20*time.Minute, func() bool { return n.heading.GPSCorrected() && w.north > 60 })
	if !n.heading.GPSCorrected() {
		t.Fatal("no straight walk measured the heading")
	}
	h, _ = n.heading.True(w.t, math.Remainder(50-w.heading, 360))
	if e := math.Abs(wrap180(h - w.heading)); e > 8 {
		t.Fatalf("heading still %.1f deg off after the GPS corrections", e)
	}
}

func TestNothingMovesWithoutTheAppsCommands(t *testing.T) {
	w := newWorld()
	n := newNav(t, w, DefaultConfig())
	settle(n, w)
	n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_GO_TO, Points: []*pb.GeoPoint{gp(at(0, 20))}})
	for range 50 {
		w.t = w.t.Add(100 * time.Millisecond)
		n.Update()
	}
	if st := n.Status().State; st != pb.NavState_NAV_STATE_READY {
		t.Fatalf("state %v without Commands, want ready", st)
	}
	if sit := n.Steer(&pb.Command{Mode: pb.Mode_MODE_SIT}); sit.Vx != 0 {
		t.Fatal("moved while sitting")
	}
}

func TestStickOrStopCancels(t *testing.T) {
	for name, c := range map[string]*pb.Command{"stick": walk(0, 0.6), "stop": {Mode: pb.Mode_MODE_WALK, Estop: true}} {
		w := newWorld()
		n := newNav(t, w, DefaultConfig())
		settle(n, w)
		n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_GO_TO, Points: []*pb.GeoPoint{gp(at(0, 20))}})
		if out := n.Steer(c); out != c {
			t.Errorf("%s: the pilot's Command was changed", name)
		}
		if st := n.Status(); st.Mission != 0 || st.Resumable {
			t.Errorf("%s: mission %v resumable %v, want cancelled", name, st.Mission, st.Resumable)
		}
	}
}

func TestWaitsForGPSHeadingAndObstacles(t *testing.T) {
	w := newWorld()
	n := newNav(t, w, DefaultConfig())
	settle(n, w)
	n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_GO_TO, Points: []*pb.GeoPoint{gp(at(0, 20))}})
	w.blocked = true
	if out := n.Steer(walk(0, 0)); out.Vx != 0 || n.Status().State != pb.NavState_NAV_STATE_BLOCKED {
		t.Fatalf("obstacle ahead: %v, %v", out, n.Status().State)
	}
	w.blocked, w.noFix = false, true
	n.Update()
	if out := n.Steer(walk(0, 0)); out.Vx != 0 || n.Status().State != pb.NavState_NAV_STATE_WAITING_GPS {
		t.Fatalf("no fix: %v, %v", out, n.Status().State)
	}
}

func TestFence(t *testing.T) {
	w := newWorld()
	n := newNav(t, w, DefaultConfig())
	settle(n, w)
	fence := []*pb.GeoPoint{gp(at(-10, -10)), gp(at(10, -10)), gp(at(10, 10)), gp(at(-10, 10))}
	if st := n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_SET_FENCE, Points: fence}); st.Refused != 0 || len(st.Fence) != 4 {
		t.Fatalf("fence not set: %v", st.Refused)
	}
	if st := n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_GO_TO, Points: []*pb.GeoPoint{gp(at(0, 30))}}); st.Refused != pb.NavRefusal_NAV_REFUSAL_OUTSIDE_FENCE {
		t.Fatalf("a goal beyond the fence: %v", st.Refused)
	}
	// Carried out (north of the fence, facing north): only turning or
	// walking back in.
	w.north = 15
	settle(n, w)
	if st := n.Status().State; st != pb.NavState_NAV_STATE_OUTSIDE_FENCE {
		t.Fatalf("state %v", st)
	}
	if out := n.Steer(walk(1, 0)); out.Vx != 0 {
		t.Fatal("walked farther out")
	}
	if out := n.Steer(walk(-1, 0.5)); out.Vx != -1 || out.YawRate != 0.5 {
		t.Fatalf("walking back in was stopped: %v", out)
	}
}

func TestPatrolLoops(t *testing.T) {
	w := newWorld()
	n := newNav(t, w, DefaultConfig())
	settle(n, w)
	route := []*pb.GeoPoint{gp(at(0, 12)), gp(at(12, 12)), gp(at(12, 0))}
	n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_SET_ROUTE, Points: route})
	if st := n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_PATROL, Loop: true}); st.Mission != pb.NavAction_NAV_ACTION_PATROL {
		t.Fatalf("patrol not started: %v", st.Refused)
	}
	seen := map[uint32]bool{}
	run(n, w, 40*time.Minute, func() bool {
		seen[n.Status().Waypoint] = true
		return len(seen) == 3 && n.Status().Waypoint == 0
	})
	if len(seen) != 3 || n.Status().Mission != pb.NavAction_NAV_ACTION_PATROL {
		t.Fatalf("waypoints visited %v, mission %v", seen, n.Status().Mission)
	}
}

func TestHomeSuspendAndResume(t *testing.T) {
	w := newWorld()
	n := newNav(t, w, DefaultConfig())
	if st := n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_GO_HOME}); st.Refused != pb.NavRefusal_NAV_REFUSAL_NO_HOME {
		t.Fatalf("home before any fix: %v", st.Refused)
	}
	settle(n, w)
	if !n.Status().HomeSet {
		t.Fatal("home not set at the first fixes")
	}
	w.east = 15
	settle(n, w)
	n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_GO_HOME})
	n.Suspend() // the app went
	if st := n.Status(); st.Mission != 0 || !st.Resumable {
		t.Fatalf("after the link went: mission %v resumable %v", st.Mission, st.Resumable)
	}
	if st := n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_RESUME}); st.Mission != pb.NavAction_NAV_ACTION_GO_HOME {
		t.Fatalf("resume: %v", st.Refused)
	}
	run(n, w, 15*time.Minute, func() bool { return n.Status().State == pb.NavState_NAV_STATE_ARRIVED })
	if d := math.Hypot(w.east, w.north); d > 4 {
		t.Fatalf("%.1f m from home", d)
	}
}

func TestNoMissionWhileFollowing(t *testing.T) {
	w := newWorld()
	w.following = true
	n := newNav(t, w, DefaultConfig())
	settle(n, w)
	if st := n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_GO_HOME}); st.Refused != pb.NavRefusal_NAV_REFUSAL_FOLLOWING {
		t.Fatalf("refused %v", st.Refused)
	}
}

func TestBatteryLowSuggestsHome(t *testing.T) {
	w := newWorld()
	n := newNav(t, w, DefaultConfig())
	n.Update()
	if n.Status().BatteryLow {
		t.Fatal("12 V is not low")
	}
	w.battery = 10.2
	if !n.Status().BatteryLow {
		t.Fatal("3.4 V per cell should suggest home")
	}
}

func TestFenceAndRouteAreKept(t *testing.T) {
	store := filepath.Join(t.TempDir(), "nav.json")
	cfg := DefaultConfig()
	cfg.Store = store
	w := newWorld()
	n := newNav(t, w, cfg)
	n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_SET_FENCE,
		Points: []*pb.GeoPoint{gp(at(-50, -50)), gp(at(50, -50)), gp(at(0, 50))}})
	n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_SET_ROUTE, Points: []*pb.GeoPoint{gp(at(0, 10)), gp(at(10, 0))}})
	again := newNav(t, w, cfg)
	if st := again.Status(); len(st.Fence) != 3 || len(st.Route) != 2 {
		t.Fatalf("after a restart: fence %d route %d", len(st.Fence), len(st.Route))
	}
}

func TestDriveOffOnlyWaits(t *testing.T) {
	w := newWorld()
	n := New(DefaultConfig(), w.inputs(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	n.now = func() time.Time { return w.t }
	settle(n, w)
	n.Request(&pb.NavRequest{Action: pb.NavAction_NAV_ACTION_GO_TO, Points: []*pb.GeoPoint{gp(at(0, 20))}})
	c := walk(0, 0)
	if out := n.Steer(c); out != c {
		t.Fatal("steered with nav.drive off")
	}
	if st := n.Status(); st.DriveEnabled || st.State != pb.NavState_NAV_STATE_READY {
		t.Fatalf("drive %v state %v", st.DriveEnabled, st.State)
	}
}
