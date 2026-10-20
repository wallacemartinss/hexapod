package nav

import "math"

const earthRadiusM = 6371000.0

// Point is a WGS84 position, degrees.
type Point struct{ Lat, Lon float64 }

// valid: on Earth, and not the 0,0 a missing fix reads as.
func (p Point) valid() bool {
	return p.Lat >= -90 && p.Lat <= 90 && p.Lon >= -180 && p.Lon <= 180 && (p.Lat != 0 || p.Lon != 0)
}

// local is p in metres east and north of origin: flat-Earth, plenty for
// the few hundred metres a walking robot covers.
func local(origin, p Point) (east, north float64) {
	lat0 := origin.Lat * math.Pi / 180
	east = (p.Lon - origin.Lon) * math.Pi / 180 * earthRadiusM * math.Cos(lat0)
	north = (p.Lat - origin.Lat) * math.Pi / 180 * earthRadiusM
	return east, north
}

// Distance in metres.
func Distance(a, b Point) float64 {
	e, n := local(a, b)
	return math.Hypot(e, n)
}

// Bearing from a to b, degrees from true north, clockwise, 0..360.
func Bearing(a, b Point) float64 {
	e, n := local(a, b)
	return wrap360(math.Atan2(e, n) * 180 / math.Pi)
}

// Inside: p within the polygon (even-odd rule, edges in order).
func Inside(p Point, poly []Point) bool {
	if len(poly) < 3 {
		return true // no fence
	}
	in := false
	for i, j := 0, len(poly)-1; i < len(poly); j, i = i, i+1 {
		xi, yi := local(p, poly[i])
		xj, yj := local(p, poly[j])
		if (yi > 0) != (yj > 0) && 0 < (xj-xi)*(0-yi)/(yj-yi)+xi {
			in = !in
		}
	}
	return in
}

// centroid of the polygon's corners: the way back in from outside.
func centroid(poly []Point) Point {
	var c Point
	for _, p := range poly {
		c.Lat += p.Lat
		c.Lon += p.Lon
	}
	n := float64(len(poly))
	return Point{c.Lat / n, c.Lon / n}
}

func wrap360(d float64) float64 {
	d = math.Mod(d, 360)
	if d < 0 {
		d += 360
	}
	return d
}

// wrap180 brings an angle difference to -180..180.
func wrap180(d float64) float64 { return math.Remainder(d, 360) }
