// tee/ansi_html.odin
//
// Replays a captured ANSI byte stream through a minimal terminal emulator
// (cursor moves, erases, CR/LF, SGR) and spits out HTML. The emulator matters:
// muninn's STREAM grouping redraws its box in place with cursor-up, so a dumb
// strip-the-escapes dump would give you fifteen copies of the same box.
//
// No os/platform dependencies in here - pure bytes in, string out.
package tee

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// ESC[2J starts a fresh region below instead of nuking everything above it.
// This is a log, not a screen - you almost certainly want true here.
KEEP_SCROLLBACK :: true

Color :: union {
	u8, // palette index 0-255
	[3]u8, // truecolor
}

Style :: struct {
	fg, bg:    Color,
	bold:      bool,
	dim:       bool,
	italic:    bool,
	underline: bool,
	reverse:   bool,
}

@(private)
Cell :: struct {
	r:  rune,
	st: Style,
}

@(private)
Screen :: struct {
	lines: [dynamic][dynamic]Cell,
	row:   int,
	col:   int,
	st:    Style,
}

to_html :: proc(raw: []u8, title := "raw_out") -> string {
	s := Screen{}
	defer {
		for &l in s.lines do delete(l)
		delete(s.lines)
	}
	feed(&s, raw)
	return render(&s, title)
}

/***************************************************************************************************
 * emulator
***************************************************************************************************/

@(private)
ensure_row :: proc(s: ^Screen, row: int) {
	for len(s.lines) <= row do append(&s.lines, make([dynamic]Cell))
}

@(private)
put :: proc(s: ^Screen, r: rune) {
	ensure_row(s, s.row)
	for len(s.lines[s.row]) <= s.col do append(&s.lines[s.row], Cell{r = ' '})
	s.lines[s.row][s.col] = Cell{r, s.st}
	s.col += 1
}

@(private)
feed :: proc(s: ^Screen, data: []u8) {
	i := 0
	for i < len(data) {
		switch data[i] {
		case '\n':
			s.row += 1
			s.col = 0
			i += 1
		case '\r':
			s.col = 0
			i += 1
		case '\t':
			s.col = ((s.col / 8) + 1) * 8
			i += 1
		case 0x08:
			if s.col > 0 do s.col -= 1
			i += 1
		case 0x1b:
			i = escape(s, data, i)
		case:
			r, w := utf8.decode_rune(data[i:])
			if w <= 0 {
				i += 1
				continue
			}
			if r >= 0x20 do put(s, r)
			i += w
		}
	}
}

@(private)
escape :: proc(s: ^Screen, data: []u8, at: int) -> int {
	i := at + 1
	if i >= len(data) do return len(data)

	switch data[i] {
	case '[':
		i += 1
		j := i
		for j < len(data) && !(data[j] >= 0x40 && data[j] <= 0x7e) do j += 1
		if j >= len(data) do return len(data)
		csi(s, string(data[i:j]), data[j])
		return j + 1
	case ']':
		// OSC - runs until BEL or ST
		i += 1
		for i < len(data) {
			if data[i] == 0x07 do return i + 1
			if data[i] == 0x1b && i + 1 < len(data) && data[i + 1] == '\\' do return i + 2
			i += 1
		}
		return len(data)
	case '(', ')', '#':
		return min(i + 2, len(data))
	case:
		return i + 1
	}
}

@(private)
csi :: proc(s: ^Screen, body: string, final: u8) {
	// private sequences (?25l cursor hide, ?1049h altbuf, mouse...) - not our problem
	if len(body) > 0 && (body[0] < '0' || body[0] > '9') && body[0] != ';' do return

	ps: [24]int
	np := 0
	{
		cur := 0
		for ch in transmute([]u8)body {
			switch {
			case ch >= '0' && ch <= '9':
				cur = cur * 10 + int(ch - '0')
			case ch == ';':
				if np < len(ps) {
					ps[np] = cur
					np += 1
				}
				cur = 0
			}
		}
		if np < len(ps) {
			ps[np] = cur
			np += 1
		}
	}

	p := ps[:np]
	n := max(1, p[0])

	switch final {
	case 'm':
		sgr(&s.st, p)
	case 'A':
		s.row = max(0, s.row - n)
	case 'B':
		s.row += n
	case 'C':
		s.col += n
	case 'D':
		s.col = max(0, s.col - n)
	case 'E':
		s.row += n
		s.col = 0
	case 'F':
		s.row = max(0, s.row - n)
		s.col = 0
	case 'G':
		s.col = max(0, n - 1)
	case 'H', 'f':
		s.row = max(0, n - 1)
		s.col = np > 1 ? max(0, p[1] - 1) : 0
	case 'K':
		erase_line(s, p[0])
	case 'J':
		erase_display(s, p[0])
	}
}

@(private)
erase_line :: proc(s: ^Screen, mode: int) {
	ensure_row(s, s.row)
	n := len(s.lines[s.row])
	switch mode {
	case 0:
		if s.col < n do resize(&s.lines[s.row], s.col)
	case 1:
		for i in 0 ..< min(s.col + 1, n) do s.lines[s.row][i] = Cell{r = ' '}
	case 2:
		clear(&s.lines[s.row])
	}
}

@(private)
erase_display :: proc(s: ^Screen, mode: int) {
	switch mode {
	case 0:
		erase_line(s, 0)
		for i in s.row + 1 ..< len(s.lines) do delete(s.lines[i])
		if len(s.lines) > s.row + 1 do resize(&s.lines, s.row + 1)
	case 1:
		for i in 0 ..< min(s.row, len(s.lines)) do clear(&s.lines[i])
		erase_line(s, 1)
	case 2, 3:
		when KEEP_SCROLLBACK {
			s.row = len(s.lines)
			s.col = 0
		} else {
			for &l in s.lines do delete(l)
			clear(&s.lines)
			s.row = 0
			s.col = 0
		}
	}
}

@(private)
sgr :: proc(st: ^Style, ps: []int) {
	i := 0
	for i < len(ps) {
		switch p := ps[i]; p {
		case 0:
			st^ = Style{}
		case 1:
			st.bold = true
		case 2:
			st.dim = true
		case 3:
			st.italic = true
		case 4:
			st.underline = true
		case 7:
			st.reverse = true
		case 22:
			st.bold = false
			st.dim = false
		case 23:
			st.italic = false
		case 24:
			st.underline = false
		case 27:
			st.reverse = false
		case 30 ..= 37:
			st.fg = u8(p - 30)
		case 39:
			st.fg = nil
		case 40 ..= 47:
			st.bg = u8(p - 40)
		case 49:
			st.bg = nil
		case 90 ..= 97:
			st.fg = u8(p - 90 + 8)
		case 100 ..= 107:
			st.bg = u8(p - 100 + 8)
		case 38, 48:
			if i + 1 >= len(ps) do break
			mode := ps[i + 1]
			if mode == 5 && i + 2 < len(ps) {
				c: Color = u8(ps[i + 2])
				if p == 38 {st.fg = c} else {st.bg = c}
				i += 2
			} else if mode == 2 && i + 4 < len(ps) {
				c: Color = [3]u8{u8(ps[i + 2]), u8(ps[i + 3]), u8(ps[i + 4])}
				if p == 38 {st.fg = c} else {st.bg = c}
				i += 4
			}
		}
		i += 1
	}
}

/***************************************************************************************************
 * palette
***************************************************************************************************/

@(private)
PAL16 := [16][3]u8 {
	{0, 0, 0},
	{205, 49, 49},
	{13, 188, 121},
	{229, 229, 16},
	{36, 114, 200},
	{188, 63, 188},
	{17, 168, 205},
	{229, 229, 229},
	{102, 102, 102},
	{241, 76, 76},
	{35, 209, 139},
	{245, 245, 67},
	{59, 142, 234},
	{214, 112, 214},
	{41, 184, 219},
	{255, 255, 255},
}

@(private)
pal_rgb :: proc(i: u8) -> [3]u8 {
	switch {
	case i < 16:
		return PAL16[i]
	case i < 232:
		LV := [6]u8{0, 95, 135, 175, 215, 255}
		n := int(i) - 16
		return {LV[n / 36], LV[(n / 6) % 6], LV[n % 6]}
	case:
		v := u8(8 + (int(i) - 232) * 10)
		return {v, v, v}
	}
}

@(private)
to_rgb :: proc(c: Color) -> [3]u8 {
	switch v in c {
	case u8:
		return pal_rgb(v)
	case [3]u8:
		return v
	}
	return {0, 0, 0}
}

/***************************************************************************************************
 * render
***************************************************************************************************/

@(private)
HEAD_A :: `<!doctype html><meta charset="utf-8"><title>`

@(private)
HEAD_B :: `</title>
<style>
  html { background:#0d0d10; }
  body { margin:0; padding:18px; }
  pre  {
    margin:0; white-space:pre; tab-size:8;
    color:#d4d4d4;
    font:13px/1.35 "Cascadia Mono","JetBrains Mono",Consolas,"DejaVu Sans Mono",monospace;
  }
</style>
<pre>`

@(private)
TAIL :: "</pre>\n"

// reverse-video swap + the usual "bold brightens a dim palette colour" rule.
// Shared by the HTML and SVG backends.
@(private)
resolve_colors :: proc(st: Style) -> (fg, bg: Color) {
	fg, bg = st.fg, st.bg
	if st.reverse {
		fg, bg = bg, fg
		if fg == nil do fg = u8(0)
		if bg == nil do bg = u8(7)
	}
	if st.bold {
		if v, ok := fg.(u8); ok && v < 8 do fg = v + 8
	}
	return
}

@(private)
css_for :: proc(b: ^strings.Builder, st: Style) {
	fg, bg := resolve_colors(st)
	if fg != nil {
		c := to_rgb(fg)
		fmt.sbprintf(b, "color:#%02x%02x%02x;", c[0], c[1], c[2])
	}
	if bg != nil {
		c := to_rgb(bg)
		fmt.sbprintf(b, "background:#%02x%02x%02x;", c[0], c[1], c[2])
	}
	if st.bold do strings.write_string(b, "font-weight:700;")
	if st.dim do strings.write_string(b, "opacity:.6;")
	if st.italic do strings.write_string(b, "font-style:italic;")
	if st.underline do strings.write_string(b, "text-decoration:underline;")
}

// index one past the last cell that actually carries information - trailing
// unstyled blanks are just cursor drift and get dropped
@(private)
trimmed_end :: proc(line: []Cell) -> int {
	end := len(line)
	for end > 0 {
		c := line[end - 1]
		if (c.r == ' ' || c.r == 0) && c.st.bg == nil && !c.st.underline && !c.st.reverse {
			end -= 1
		} else {
			break
		}
	}
	return end
}

@(private)
write_escaped :: proc(b: ^strings.Builder, r: rune) {
	switch r {
	case 0:
		strings.write_byte(b, ' ')
	case '&':
		strings.write_string(b, "&amp;")
	case '<':
		strings.write_string(b, "&lt;")
	case '>':
		strings.write_string(b, "&gt;")
	case:
		strings.write_rune(b, r)
	}
}

@(private)
render :: proc(s: ^Screen, title: string) -> string {
	b := strings.builder_make()
	css := strings.builder_make()
	defer strings.builder_destroy(&css)

	strings.write_string(&b, HEAD_A)
	for r in title do write_escaped(&b, r)
	strings.write_string(&b, HEAD_B)

	for &line in s.lines {
		end := trimmed_end(line[:])

		i := 0
		for i < end {
			st := line[i].st
			j := i
			for j < end && line[j].st == st do j += 1

			strings.builder_reset(&css)
			css_for(&css, st)
			tag := strings.to_string(css)

			if tag != "" {
				strings.write_string(&b, "<span style=\"")
				strings.write_string(&b, tag)
				strings.write_string(&b, "\">")
			}
			for k in i ..< j do write_escaped(&b, line[k].r)
			if tag != "" do strings.write_string(&b, "</span>")
			i = j
		}
		strings.write_byte(&b, '\n')
	}

	strings.write_string(&b, TAIL)
	return strings.to_string(b)
}
