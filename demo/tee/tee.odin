// tee/tee.odin
//
// Eats the process's stdout+stderr, tees it to the real console, and dumps the
// whole run to an HTML file with the colors intact.
//
//   tee.start()          <- BEFORE mn.init()
//   defer tee.stop()
//
// Written against os2 (the `core:os` where os.stdout is a ^File). Catches
// anything that writes through os.stdout/os.stderr: fmt.print*, muninn,
// core:log via the bridge. Raw win32 WriteFile-to-GetStdHandle callers are NOT
// caught - nothing in muninn does that.
package tee

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import win "core:sys/windows"

@(private)
State :: struct {
	on:       bool,
	path:     string,
	real_out: ^os.File,
	real_err: ^os.File,
	pipe_r:   ^os.File,
	pipe_w:   ^os.File,
	pumper:   ^thread.Thread,
	mu:       sync.Mutex,
	raw:      [dynamic]u8,
}

@(private)
g: State

start :: proc(path := "./assets/demo.svg") -> bool {
	if g.on do return true

	// we become the only writer to the console, so make sure IT groks ANSI
	enable_vt()

	r, w, err := os.pipe()
	if err != nil {
		fmt.eprintfln("[tee] pipe failed: %v", err)
		return false
	}

	g.path = strings.clone(path)
	g.raw = make([dynamic]u8, 0, 1 << 16)
	g.real_out = os.stdout
	g.real_err = os.stderr
	g.pipe_r = r
	g.pipe_w = w

	os.stdout = w
	os.stderr = w

	g.on = true
	g.pumper = thread.create(pump)
	thread.start(g.pumper)
	return true
}

stop :: proc() {
	if !g.on do return
	g.on = false

	os.stdout = g.real_out
	os.stderr = g.real_err

	_ = os.close(g.pipe_w)
	thread.join(g.pumper)
	thread.destroy(g.pumper)
	_ = os.close(g.pipe_r)

	n := write_file()
	fmt.printfln("[tee] wrote %s (%d bytes captured)", g.path, n)

	delete(g.raw)
	delete(g.path)
}

// Dump what we have so far without shutting anything down. Call this before any
// path that panics (mn.fatal) - Odin does not unwind, so `defer stop()` never fires.
snapshot :: proc() {
	if !g.on do return
	write_file()
}

console :: proc() -> ^os.File {
	return g.on ? g.real_out : os.stdout
}

cols :: proc() -> int {
	info: win.CONSOLE_SCREEN_BUFFER_INFO
	if win.GetConsoleScreenBufferInfo(console_handle(), &info) {
		w := int(info.srWindow.Right - info.srWindow.Left) + 1
		if w > 1 do return w
	}
	return 80
}

@(private)
pump :: proc(t: ^thread.Thread) {
	buf: [8192]u8
	for {
		n, err := os.read(g.pipe_r, buf[:])
		if n > 0 {
			_, _ = os.write(g.real_out, buf[:n])
			sync.mutex_lock(&g.mu)
			append(&g.raw, ..buf[:n])
			sync.mutex_unlock(&g.mu)
		}
		if err != nil do break
	}
}

@(private)
write_file :: proc() -> int {
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)

	// .svg for a README, anything else gets HTML
	out := strings.has_suffix(g.path, ".svg") ? to_svg(g.raw[:]) : to_html(g.raw[:], g.path)
	defer delete(out)

	if err := os.write_entire_file(g.path, transmute([]u8)out); err != nil {
		fmt.eprintfln("[tee] could not write %s: %v", g.path, err)
	}
	return len(g.raw)
}

@(private)
console_handle :: proc() -> win.HANDLE {
	return win.GetStdHandle(win.STD_OUTPUT_HANDLE)
}

@(private)
ENABLE_VT :: win.DWORD(0x0004) // ENABLE_VIRTUAL_TERMINAL_PROCESSING

@(private)
enable_vt :: proc() {
	h := console_handle()
	mode: win.DWORD
	if win.GetConsoleMode(h, &mode) {
		win.SetConsoleMode(h, mode | ENABLE_VT)
	}
}
