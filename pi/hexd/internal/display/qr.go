package display

import "rsc.io/qr"

// QR draws text as a QR code at the left edge, as large as the panel's
// height allows: lit background and quiet zone, dark modules (the usual
// polarity; many phone scanners do not read inverted codes). It returns
// the width used, or 0 when the text does not fit.
func (f *Frame) QR(text string) int {
	code, err := qr.Encode(text, qr.M)
	if err != nil {
		return 0
	}
	scale := Height / (code.Size + 4) // at least 2 modules of quiet zone per side
	if scale < 1 {
		return 0
	}
	side := code.Size*scale + 4*scale
	if extra := (Height - side) / 2; extra > 0 { // spend leftover on a wider quiet zone
		side += 2 * extra
	}
	quiet := (side - code.Size*scale) / 2
	top := (Height - side) / 2
	for y := 0; y < side; y++ {
		for x := 0; x < side; x++ {
			mx, my := (x-quiet)/scale, (y-quiet)/scale
			dark := x >= quiet && y >= quiet && mx < code.Size && my < code.Size && code.Black(mx, my)
			f.set(x, top+y, !dark)
		}
	}
	return side
}

func (f *Frame) set(x, y int, on bool) {
	if x < 0 || x >= Width || y < 0 || y >= Height {
		return
	}
	bit := byte(1) << (y % 8)
	if on {
		f[y/8][x] |= bit
	} else {
		f[y/8][x] &^= bit
	}
}
