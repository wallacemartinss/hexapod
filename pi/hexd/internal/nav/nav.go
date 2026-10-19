// Package nav walks the robot by GPS: to a point, home, along a patrol
// route, and keeps it inside a virtual fence.
//
// As follow me (internal/vision), it never sends a Command of its own: it
// replaces the speeds of the app's walk Commands while a mission runs and
// the sticks are at rest. No app, no Commands, nothing moves; a stick or
// STOP cancels the mission; the ESP32 failsafe works as always.
package nav

import (
	"context"
	"encoding/json"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"sync"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"google.golang.org/protobuf/proto"
)

const (
	// TakeOver: a stick past this (any axis, -1..1) cancels the mission.
	TakeOver = 0.2
	// steerFresh: the robot counts as driven while Steer ran this recently.
	steerFresh = 300 * time.Millisecond
	// fixWindow: fixes averaged into the position (1 Hz: ~0.4 m behind at
	// full speed, and much steadier).
	fixWindow = 5
	// compassMaxAge: older Compass frames are not used.
	compassMaxAge = time.Second
	// fenceReach: a fence farther than this was drawn somewhere else (the
	// robot was carried away): it is not enforced here.
	fenceReach = 1000.0 // m
	maxPoints  = 64
	publishGap = 500 * time.Millisecond
)

// Config tunes the navigation (hexd.yaml nav:).
type Config struct {
	Drive       bool    // steer the app's walk Commands; off: missions wait in READY
	ArriveM     float64 // a point counts as reached this close, m
	MaxHdop     float64 // a fix poorer than this does not count
	Declination float64 // deg, true = magnetic + declination
	MaxSpeed    float64 // vx, 0..1
	MaxTurn     float64 // yaw_rate, 0..1
	TurnFirst   float64 // deg off the target: turn on the spot first
	SlowM       float64 // m from the target where the robot starts slowing down
	Cells       int     // battery cells in series
	LowCellV    float64 // V per cell: suggest going home below this
	Store       string  // JSON file keeping the fence and the route ("": not kept)
}

// DefaultConfig: careful, for a slow robot and a NEO-6M.
func DefaultConfig() Config {
	return Config{ArriveM: 3, MaxHdop: 3, MaxSpeed: 0.6, MaxTurn: 0.6, TurnFirst: 30, SlowM: 5,
		Cells: 3, LowCellV: 3.5}
}

// Inputs are read on every update; any may return nothing.
type Inputs struct {
	Position  func() (*pb.Position, bool)     // GPS
	Telemetry func() *pb.Telemetry            // nil: no ESP32
	Compass   func() (*pb.Compass, time.Time) // nil: none yet
	Following func() bool                     // follow me has a target
}

type fix struct {
	p    Point
	hdop float64
	utc  uint64
}

// Navigator is safe for concurrent use.
type Navigator struct {
	cfg Config
	in  Inputs
	log *slog.Logger
	now func() time.Time

	mu        sync.Mutex
	heading   Heading
	fixes     []fix
	pos       Point
	posOK     bool
	home      Point
	homeSet   bool
	fence     []Point
	route     []Point
	loop      bool
	mission   pb.NavAction // GO_TO, GO_HOME, PATROL; UNSPECIFIED = none
	target    Point
	waypoint  int
	arrived   bool
	refused   pb.NavRefusal
	suspended *suspended // what the lost link interrupted
	state     pb.NavState
	steeredAt time.Time
	lastVx    float64 // what drive gave the last Command
	lastYaw   float64
	outside   bool
	subs      map[chan *pb.NavStatus]struct{}
	published *pb.NavStatus
	pubAt     time.Time
}

type suspended struct {
	mission  pb.NavAction
	target   Point
	waypoint int
}

// New makes an idle navigator, with the fence and route kept in cfg.Store.
func New(cfg Config, in Inputs, log *slog.Logger) *Navigator {
	n := &Navigator{cfg: cfg, in: in, log: log, now: time.Now, subs: map[chan *pb.NavStatus]struct{}{},
		state: pb.NavState_NAV_STATE_IDLE}
	n.heading.Declination = cfg.Declination
	n.load()
	return n
}

// Run updates the navigation at 10 Hz until ctx ends.
func (n *Navigator) Run(ctx context.Context) {
	t := time.NewTicker(100 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			n.Update()
		}
	}
}

// Update reads the inputs, moves the mission on and tells the subscribers.
func (n *Navigator) Update() {
	n.mu.Lock()
	defer n.mu.Unlock()
	now := n.now()
	tel := n.telemetry()
	if tel != nil && tel.Orientation != nil {
		mag, acc := 0.0, 0.0
		if n.in.Compass != nil {
			if c, at := n.in.Compass(); c != nil && now.Sub(at) < compassMaxAge {
				mag, acc = float64(c.HeadingDeg), float64(c.AccuracyDeg)
			}
		}
		n.heading.Compass(now, float64(tel.YawDeg), mag, acc)
	}
	n.readGPS(now, tel)
	n.refresh(now, tel)
	n.publish(now, false)
}

func (n *Navigator) telemetry() *pb.Telemetry {
	if n.in.Telemetry == nil {
		return nil
	}
	return n.in.Telemetry()
}

// readGPS keeps the newest good fixes and their mean as the position.
func (n *Navigator) readGPS(now time.Time, tel *pb.Telemetry) {
	if n.in.Position == nil {
		n.posOK = false
		return
	}
	p, talking := n.in.Position()
	if !talking || p == nil || !p.Fix || float64(p.Hdop) > n.cfg.MaxHdop {
		n.posOK, n.fixes = false, n.fixes[:0]
		return
	}
	if len(n.fixes) > 0 && n.fixes[len(n.fixes)-1].utc == p.UtcMs {
		return // the same reading again (the GPS speaks once a second)
	}
	f := fix{Point{p.LatitudeDeg, p.LongitudeDeg}, float64(p.Hdop), p.UtcMs}
	if !f.p.valid() {
		return
	}
	n.fixes = append(n.fixes, f)
	if len(n.fixes) > fixWindow {
		n.fixes = n.fixes[1:]
	}
	var sum Point
	for _, f := range n.fixes {
		sum.Lat += f.p.Lat
		sum.Lon += f.p.Lon
	}
	k := float64(len(n.fixes))
	n.pos, n.posOK = Point{sum.Lat / k, sum.Lon / k}, true
	if !n.homeSet && len(n.fixes) == fixWindow {
		n.home, n.homeSet = n.pos, true // where the robot was switched on
		n.log.Info("home set where the robot started", "lat", n.pos.Lat, "lon", n.pos.Lon)
	}
	if tel != nil && tel.Orientation != nil {
		// The heading learns from the walk only when the robot walked
		// straight ahead on its own speeds (ours, while driving).
		n.heading.Walk(now, f.p, f.hdop, n.walkingStraight(now), float64(tel.YawDeg))
	}
}

// walkingStraight: hexd drove the robot forward without turning, just now.
func (n *Navigator) walkingStraight(now time.Time) bool {
	return n.state == pb.NavState_NAV_STATE_DRIVING && now.Sub(n.steeredAt) < steerFresh && n.lastVx > 0.2 &&
		math.Abs(n.lastYaw) < 0.05
}

// refresh derives the state from the mission and the inputs.
func (n *Navigator) refresh(now time.Time, tel *pb.Telemetry) {
	n.outside = n.posOK && n.fenceHere() && !Inside(n.pos, n.fence)
	_, headingOK := n.trueHeading(now, tel)
	switch {
	case n.mission == pb.NavAction_NAV_ACTION_UNSPECIFIED:
		n.state = pb.NavState_NAV_STATE_IDLE
		if n.arrived {
			n.state = pb.NavState_NAV_STATE_ARRIVED
		}
		if n.outside {
			n.state = pb.NavState_NAV_STATE_OUTSIDE_FENCE
		}
	case !n.posOK:
		n.state = pb.NavState_NAV_STATE_WAITING_GPS
	case n.outside:
		n.log.Warn("outside the fence: mission stopped")
		n.stopLocked()
		n.state = pb.NavState_NAV_STATE_OUTSIDE_FENCE
	case !headingOK:
		n.state = pb.NavState_NAV_STATE_WAITING_HEADING
	case Distance(n.pos, n.target) <= n.cfg.ArriveM:
		if n.mission == pb.NavAction_NAV_ACTION_PATROL && (n.waypoint+1 < len(n.route) || n.loop) {
			n.waypoint = (n.waypoint + 1) % len(n.route)
			n.target = n.route[n.waypoint]
			n.log.Info("patrol: next point", "waypoint", n.waypoint)
			n.state = pb.NavState_NAV_STATE_READY // the next update measures the new point
			return
		}
		n.log.Info("arrived", "mission", n.mission)
		n.stopLocked()
		n.arrived = true
		n.state = pb.NavState_NAV_STATE_ARRIVED
	case tel != nil && tel.BlockedMask&1 != 0:
		n.state = pb.NavState_NAV_STATE_BLOCKED
	case now.Sub(n.steeredAt) < steerFresh:
		n.state = pb.NavState_NAV_STATE_DRIVING
	default:
		n.state = pb.NavState_NAV_STATE_READY
	}
}

func (n *Navigator) trueHeading(now time.Time, tel *pb.Telemetry) (float64, bool) {
	if tel == nil || tel.Orientation == nil {
		return 0, false
	}
	return n.heading.True(now, float64(tel.YawDeg))
}

func (n *Navigator) fenceHere() bool {
	return len(n.fence) >= 3 && Distance(n.pos, centroid(n.fence)) < fenceReach
}

func (n *Navigator) stopLocked() {
	n.mission, n.waypoint, n.suspended = pb.NavAction_NAV_ACTION_UNSPECIFIED, 0, nil
}

// Request takes the app's NavRequest; the answer is in the new status
// (refused tells why it was turned down).
func (n *Navigator) Request(r *pb.NavRequest) *pb.NavStatus {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.refused = n.apply(r)
	if n.refused != pb.NavRefusal_NAV_REFUSAL_UNSPECIFIED {
		n.log.Info("nav request refused", "action", r.Action, "why", n.refused)
	}
	now := n.now()
	n.refresh(now, n.telemetry())
	return n.publish(now, true)
}

func (n *Navigator) apply(r *pb.NavRequest) pb.NavRefusal {
	if len(r.Points) > maxPoints {
		return pb.NavRefusal_NAV_REFUSAL_BAD_POINTS
	}
	pts := make([]Point, 0, len(r.Points))
	for _, p := range r.Points {
		q := Point{p.LatitudeDeg, p.LongitudeDeg}
		if !q.valid() {
			return pb.NavRefusal_NAV_REFUSAL_BAD_POINTS
		}
		pts = append(pts, q)
	}
	starting := r.Action == pb.NavAction_NAV_ACTION_GO_TO || r.Action == pb.NavAction_NAV_ACTION_GO_HOME ||
		r.Action == pb.NavAction_NAV_ACTION_PATROL || r.Action == pb.NavAction_NAV_ACTION_RESUME
	if starting && n.in.Following != nil && n.in.Following() {
		return pb.NavRefusal_NAV_REFUSAL_FOLLOWING
	}
	if starting {
		n.arrived = false
	}
	switch r.Action {
	case pb.NavAction_NAV_ACTION_STOP:
		n.stopLocked()
	case pb.NavAction_NAV_ACTION_GO_TO:
		if len(pts) != 1 {
			return pb.NavRefusal_NAV_REFUSAL_BAD_POINTS
		}
		if !n.allowed(pts[0]) {
			return pb.NavRefusal_NAV_REFUSAL_OUTSIDE_FENCE
		}
		n.start(pb.NavAction_NAV_ACTION_GO_TO, pts[0], 0)
	case pb.NavAction_NAV_ACTION_GO_HOME:
		if !n.homeSet {
			return pb.NavRefusal_NAV_REFUSAL_NO_HOME
		}
		if !n.allowed(n.home) {
			return pb.NavRefusal_NAV_REFUSAL_OUTSIDE_FENCE
		}
		n.start(pb.NavAction_NAV_ACTION_GO_HOME, n.home, 0)
	case pb.NavAction_NAV_ACTION_PATROL:
		if len(n.route) < 2 {
			return pb.NavRefusal_NAV_REFUSAL_NO_ROUTE
		}
		if n.loop != r.Loop {
			n.loop = r.Loop
			n.save()
		}
		// Start at the nearest point of the route: no walk back to the first.
		first := 0
		if n.posOK {
			for i, p := range n.route {
				if Distance(n.pos, p) < Distance(n.pos, n.route[first]) {
					first = i
				}
			}
		}
		n.start(pb.NavAction_NAV_ACTION_PATROL, n.route[first], first)
	case pb.NavAction_NAV_ACTION_RESUME:
		s := n.suspended
		if s == nil {
			return pb.NavRefusal_NAV_REFUSAL_NOTHING_TO_RESUME
		}
		n.start(s.mission, s.target, s.waypoint)
	case pb.NavAction_NAV_ACTION_SET_HOME:
		switch {
		case len(pts) == 1:
			n.home = pts[0]
		case len(pts) == 0 && n.posOK:
			n.home = n.pos
		case len(pts) == 0:
			return pb.NavRefusal_NAV_REFUSAL_NO_POSITION
		default:
			return pb.NavRefusal_NAV_REFUSAL_BAD_POINTS
		}
		n.homeSet = true
	case pb.NavAction_NAV_ACTION_SET_FENCE:
		if len(pts) > 0 && len(pts) < 3 {
			return pb.NavRefusal_NAV_REFUSAL_BAD_POINTS
		}
		n.fence = pts
		n.save()
	case pb.NavAction_NAV_ACTION_SET_ROUTE:
		if len(pts) == 1 {
			return pb.NavRefusal_NAV_REFUSAL_BAD_POINTS
		}
		for _, p := range pts {
			if !n.allowed(p) {
				return pb.NavRefusal_NAV_REFUSAL_OUTSIDE_FENCE
			}
		}
		n.route = pts
		if n.mission == pb.NavAction_NAV_ACTION_PATROL {
			n.stopLocked() // the route under it changed
		}
		n.save()
	default:
		return pb.NavRefusal_NAV_REFUSAL_BAD_POINTS
	}
	return pb.NavRefusal_NAV_REFUSAL_UNSPECIFIED
}

// allowed: inside the fence (or no fence here).
func (n *Navigator) allowed(p Point) bool {
	if len(n.fence) < 3 || Distance(p, centroid(n.fence)) >= fenceReach {
		return true
	}
	return Inside(p, n.fence)
}

func (n *Navigator) start(m pb.NavAction, target Point, waypoint int) {
	n.mission, n.target, n.waypoint, n.suspended = m, target, waypoint, nil
	n.log.Info("mission started", "mission", m, "lat", target.Lat, "lon", target.Lon)
}

// Suspend: the last app went away. The mission stops (nothing moves
// without an app anyway) and RESUME can pick it up again.
func (n *Navigator) Suspend() {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.mission == pb.NavAction_NAV_ACTION_UNSPECIFIED {
		return
	}
	s := &suspended{n.mission, n.target, n.waypoint}
	n.stopLocked()
	n.suspended = s
	n.log.Info("mission suspended: no app")
	now := n.now()
	n.refresh(now, n.telemetry())
	n.publish(now, true)
}

// Active: a mission runs (follow me must not start).
func (n *Navigator) Active() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.mission != pb.NavAction_NAV_ACTION_UNSPECIFIED
}

// Steer takes an app Command on its way to the ESP32. During a mission, in
// walk mode with the sticks at rest, the speeds become the mission's (zero
// while it waits). A stick or STOP cancels the mission. Outside the fence,
// the pilot's own Commands may only turn or walk back in.
func (n *Navigator) Steer(c *pb.Command) *pb.Command {
	n.mu.Lock()
	defer n.mu.Unlock()
	now := n.now()
	if n.mission != pb.NavAction_NAV_ACTION_UNSPECIFIED {
		if c.Estop || math.Abs(float64(c.Vx)) > TakeOver || math.Abs(float64(c.Vy)) > TakeOver ||
			math.Abs(float64(c.YawRate)) > TakeOver {
			n.log.Info("pilot took over: mission cancelled", "mission", n.mission)
			n.stopLocked()
			n.refresh(now, n.telemetry())
			n.publish(now, true)
			return n.fenced(now, c)
		}
		if c.Mode == pb.Mode_MODE_WALK && n.cfg.Drive {
			out := proto.CloneOf(c)
			out.Vx, out.Vy, out.YawRate = 0, 0, 0
			n.lastVx, n.lastYaw = 0, 0
			was := n.state
			n.steeredAt = now
			n.refresh(now, n.telemetry())
			if n.state == pb.NavState_NAV_STATE_DRIVING {
				vx, yaw := n.drive(now)
				out.Vx, out.YawRate = float32(vx), float32(yaw)
				n.lastVx, n.lastYaw = vx, yaw
			}
			if n.state != was {
				n.publish(now, true)
			}
			return out
		}
	}
	return n.fenced(now, c)
}

// drive turns towards the target, then walks, slowing down near it.
func (n *Navigator) drive(now time.Time) (vx, yawRate float64) {
	heading, _ := n.trueHeading(now, n.telemetry())
	off := wrap180(Bearing(n.pos, n.target) - heading) // + = target to the right
	if math.Abs(off) > 5 {
		yawRate = clamp(-off/n.cfg.TurnFirst*n.cfg.MaxTurn, -n.cfg.MaxTurn, n.cfg.MaxTurn) // + yaw = left
	}
	if math.Abs(off) > n.cfg.TurnFirst {
		return 0, yawRate
	}
	slow := clamp(Distance(n.pos, n.target)/n.cfg.SlowM, 0.3, 1)
	return n.cfg.MaxSpeed * slow * math.Cos(off*math.Pi/180), yawRate
}

// fenced: outside the fence, a Command may turn, and walk only back in.
// Without a trusted heading "back in" is unknown: it may only turn.
func (n *Navigator) fenced(now time.Time, c *pb.Command) *pb.Command {
	if !n.outside || (c.Vx == 0 && c.Vy == 0) {
		return c
	}
	heading, ok := n.trueHeading(now, n.telemetry())
	if ok {
		// Direction the sticks walk, world frame (vy + = left).
		dir := heading - math.Atan2(float64(c.Vy), float64(c.Vx))*180/math.Pi
		if math.Abs(wrap180(Bearing(n.pos, centroid(n.fence))-dir)) < 90 {
			return c
		}
	}
	out := proto.CloneOf(c)
	out.Vx, out.Vy = 0, 0
	return out
}

func clamp(x, lo, hi float64) float64 { return math.Max(lo, math.Min(hi, x)) }

// Status is the navigation now.
func (n *Navigator) Status() *pb.NavStatus {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.statusLocked(n.now())
}

func (n *Navigator) statusLocked(now time.Time) *pb.NavStatus {
	st := &pb.NavStatus{State: n.state, Mission: n.mission, Loop: n.loop, Refused: n.refused,
		ArriveM: float32(n.cfg.ArriveM), Resumable: n.suspended != nil, HomeSet: n.homeSet, DriveEnabled: n.cfg.Drive,
		Fence: geo(n.fence), Route: geo(n.route)}
	if n.homeSet {
		st.Home = geo([]Point{n.home})[0]
	}
	if n.mission != pb.NavAction_NAV_ACTION_UNSPECIFIED {
		st.Target, st.Waypoint = geo([]Point{n.target})[0], uint32(n.waypoint)
		if n.posOK {
			st.DistanceM, st.TargetBearingDeg = float32(Distance(n.pos, n.target)), float32(Bearing(n.pos, n.target))
		}
	}
	tel := n.telemetry()
	h, ok := n.trueHeading(now, tel)
	st.HeadingDeg, st.HeadingOk = float32(h), ok
	if tel != nil && n.cfg.Cells > 0 && tel.BatteryVoltageV > 1 {
		st.BatteryLow = float64(tel.BatteryVoltageV) < float64(n.cfg.Cells)*n.cfg.LowCellV
	}
	return st
}

func geo(ps []Point) []*pb.GeoPoint {
	out := make([]*pb.GeoPoint, len(ps))
	for i, p := range ps {
		out[i] = &pb.GeoPoint{LatitudeDeg: p.Lat, LongitudeDeg: p.Lon}
	}
	return out
}

// Subscribe streams NavStatus: on every change, and twice a second while
// anything moves. A slow reader misses some: only the newest matter.
func (n *Navigator) Subscribe() (<-chan *pb.NavStatus, func()) {
	ch := make(chan *pb.NavStatus, 4)
	n.mu.Lock()
	n.subs[ch] = struct{}{}
	n.mu.Unlock()
	return ch, func() {
		n.mu.Lock()
		delete(n.subs, ch)
		n.mu.Unlock()
	}
}

// publish sends the status when it changed in kind, when force, or every
// publishGap (heading and distance change all the time).
func (n *Navigator) publish(now time.Time, force bool) *pb.NavStatus {
	st := n.statusLocked(now)
	if !force && n.published != nil && now.Sub(n.pubAt) < publishGap && sameKind(st, n.published) {
		return st
	}
	n.published, n.pubAt = st, now
	for ch := range n.subs {
		select {
		case ch <- st:
		default:
		}
	}
	return st
}

func sameKind(a, b *pb.NavStatus) bool {
	return a.State == b.State && a.Mission == b.Mission && a.Waypoint == b.Waypoint && a.HeadingOk == b.HeadingOk &&
		a.Refused == b.Refused && a.Resumable == b.Resumable && a.BatteryLow == b.BatteryLow &&
		a.HomeSet == b.HomeSet && len(a.Fence) == len(b.Fence) && len(a.Route) == len(b.Route)
}

// stored is the Store file: places the pilot drew, kept across restarts.
// Home is not kept: it is where the robot is switched on.
type stored struct {
	Fence [][2]float64 `json:"fence,omitempty"`
	Route [][2]float64 `json:"route,omitempty"`
	Loop  bool         `json:"loop,omitempty"`
}

func (n *Navigator) load() {
	if n.cfg.Store == "" {
		return
	}
	b, err := os.ReadFile(n.cfg.Store)
	if err != nil {
		return
	}
	var s stored
	if json.Unmarshal(b, &s) != nil {
		n.log.Warn("nav store unreadable, starting empty", "path", n.cfg.Store)
		return
	}
	for _, p := range s.Fence {
		n.fence = append(n.fence, Point{p[0], p[1]})
	}
	for _, p := range s.Route {
		n.route = append(n.route, Point{p[0], p[1]})
	}
	n.loop = s.Loop
}

func (n *Navigator) save() {
	if n.cfg.Store == "" {
		return
	}
	s := stored{Loop: n.loop}
	for _, p := range n.fence {
		s.Fence = append(s.Fence, [2]float64{p.Lat, p.Lon})
	}
	for _, p := range n.route {
		s.Route = append(s.Route, [2]float64{p.Lat, p.Lon})
	}
	b, _ := json.Marshal(s)
	tmp := n.cfg.Store + ".tmp"
	if err := os.MkdirAll(filepath.Dir(n.cfg.Store), 0o755); err == nil {
		if err = os.WriteFile(tmp, b, 0o644); err == nil {
			err = os.Rename(tmp, n.cfg.Store)
		}
		if err != nil {
			n.log.Warn("nav store not saved", "err", err)
		}
	}
}
