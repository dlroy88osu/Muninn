// tee/svg.odin
//
// Same emulator, SVG out instead of HTML - because GitHub strips `style`
// attributes from markdown but happily renders an <img> pointing at an .svg.
//
//   ![demo](docs/demo.svg)
//
// Each styled run is absolutely positioned and pinned with textLength, so the
// box rails line up even when the reader's machine has a different monospace
// font than yours.
package tee

import "core:fmt"
import "core:strings"

SVG_FONT_SIZE :: 14.0
SVG_CHAR_W :: 8.4 // 0.6em, the widest common monospace advance
SVG_LINE_H :: 17.0
SVG_PAD :: 12.0
SVG_FONT :: "ui-monospace,SFMono-Regular,Menlo,Consolas,'DejaVu Sans Mono',monospace"
SVG_BG :: "#0d0d10"
SVG_FG :: "#d4d4d4"

// max_lines = 0 keeps everything, otherwise only the first N lines survive
// (a 2000-line SVG in a README is nobody's friend).
to_svg :: proc(raw: []u8, max_lines := 0) -> string {
	s := Screen{}
	defer {
		for &l in s.lines do delete(l)
		delete(s.lines)
	}
	feed(&s, raw)
	return render_svg(&s, max_lines)
}

@(private)
all_blank :: proc(run: []Cell) -> bool {
	for c in run {
		if c.r != ' ' && c.r != 0 do return false
	}
	return true
}

@(private)
render_svg :: proc(s: ^Screen, max_lines: int) -> string {
	rows := len(s.lines)
	if max_lines > 0 && rows > max_lines do rows = max_lines

	cols := 0
	for i in 0 ..< rows {
		if e := trimmed_end(s.lines[i][:]); e > cols do cols = e
	}

	w := f64(cols) * SVG_CHAR_W + 2 * SVG_PAD
	h := f64(rows) * SVG_LINE_H + 2 * SVG_PAD

	b := strings.builder_make()
	fmt.sbprintf(
		&b,
		`<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" viewBox="0 0 %.0f %.0f" font-family="%s" font-size="%.0f" fill="%s"><rect width="100%%" height="100%%" fill="%s" rx="6"/>`,
		w,
		h,
		w,
		h,
		SVG_FONT,
		SVG_FONT_SIZE,
		SVG_FG,
		SVG_BG,
	)

	for li in 0 ..< rows {
		line := s.lines[li][:]
		end := trimmed_end(line)
		if end == 0 do continue

		y := SVG_PAD + f64(li) * SVG_LINE_H

		// pass 1 - background rects
		i := 0
		for i < end {
			st := line[i].st
			j := i
			for j < end && line[j].st == st do j += 1
			if _, bg := resolve_colors(st); bg != nil {
				c := to_rgb(bg)
				fmt.sbprintf(
					&b,
					`<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="#%02x%02x%02x"/>`,
					SVG_PAD + f64(i) * SVG_CHAR_W,
					y,
					f64(j - i) * SVG_CHAR_W,
					SVG_LINE_H,
					c[0],
					c[1],
					c[2],
				)
			}
			i = j
		}

		// pass 2 - glyphs, baseline 3/4 down the cell
		ty := y + SVG_LINE_H * 0.75
		i = 0
		for i < end {
			st := line[i].st
			j := i
			for j < end && line[j].st == st do j += 1
			defer i = j

			if all_blank(line[i:j]) && !st.underline do continue

			fg, _ := resolve_colors(st)
			fmt.sbprintf(
				&b,
				`<text xml:space="preserve" x="%.2f" y="%.2f" textLength="%.2f" lengthAdjust="spacingAndGlyphs"`,
				SVG_PAD + f64(i) * SVG_CHAR_W,
				ty,
				f64(j - i) * SVG_CHAR_W,
			)
			if fg != nil {
				c := to_rgb(fg)
				fmt.sbprintf(&b, ` fill="#%02x%02x%02x"`, c[0], c[1], c[2])
			}
			if st.bold do strings.write_string(&b, ` font-weight="bold"`)
			if st.italic do strings.write_string(&b, ` font-style="italic"`)
			if st.underline do strings.write_string(&b, ` text-decoration="underline"`)
			if st.dim do strings.write_string(&b, ` opacity="0.6"`)
			strings.write_string(&b, ">")

			for k in i ..< j do write_escaped(&b, line[k].r)
			strings.write_string(&b, "</text>")
		}
	}

	strings.write_string(&b, "</svg>\n")
	return strings.to_string(b)
}
