#+feature global-context
package muninn

import "base:intrinsics"
import "base:runtime"
import "core:c/libc"
import "core:debug/trace"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"


Levels :: enum i32 {
	TRACE,
	DEBUG,
	INFO,
	WARN,
	ERROR,
	FATAL,
}

// color codes
RESET :: "\x1b[0m"
GRAY :: "\x1b[38;5;244m" // trace + location data
BLUE :: "\x1b[38;5;75m" // debug
GREEN :: "\x1b[38;5;77m" // info
YELLOW :: "\x1b[38;5;221m" // warn(ing)
RED :: "\x1b[38;5;203m" // error
MAGENTA :: "\x1b[38;5;170m" // fatal
CYAN :: "\x1b[38;5;80m"

/***************************************************************************************************
 * [ Init ]
***************************************************************************************************/

/*
init configures the logger. Every parameter is optional - anything you don't
pass is left exactly as it was, so you can call this once with everything, or
repeatedly to tweak one knob at a time.

Call it BEFORE you spawn threads. The option globals are plain (non-atomic)
variables, so reconfiguring while workers are mid-log is a data race. The one
exception is `level`, which is stored atomically and is safe to change at any
point.

Args:
  Output routing
  - save_file: write JSON lines to disk. Toggling this on/off reopens or
      closes the file handle immediately, flushing anything buffered.
  - log_dir: directory for the .jsonl files. Changing it rebuilds the log
      filename (PROG__YYYY-MM-DD.jsonl), makes the directory, and reopens.
      Defaults to `.logs/` beside your executable.
  - rotate_days: how many days of old logs to keep. Pruning happens at exit,
      and only touches files matching your program's own prefix.
  - emit_json: print JSON to stdout instead of the pretty line. Overrides
      pretty formatting entirely - colors, boxes and grouping are all skipped.

  Verbosity
  - level: minimum level to emit. Anything below is dropped before the message
      is even formatted. Safe to change at runtime from any thread.
  - verbose: print the logger's own startup diagnostics.

  Pretty formatting (ignored when emit_json is true)
  - use_color: ANSI color. Auto-detected at startup from NO_COLOR /
      FORCE_COLOR / FORCE_NO_COLOR - pass this only to override that.
  - show_location: append `file:line ( procedure )` to each line.
  - short_location: basename instead of the full path. Needs show_location.
  - show_runtime: prepend `[ HH:MM:SS ]` elapsed since process start.
  - show_timestamp: prepend `[ YYYY-MM-DD HH:MM:SS ]` local wall clock.
  - show_pid: append the process id.
  - show_tid: append the thread id. Redundant with group_by_thread, since the
      box label already carries it.

  Thread / job grouping (ignored when emit_json is true)
  - group_by_thread: buffer lines per thread and print each run inside a
      labeled box instead of interleaving them. NOTE: output is deferred -
      nothing appears until a box closes. Boxes close when the thread hits
      group_max_lines, on mn.flush(), on fatal, at exit, or when you call
      mn.reset_ctx() / pass ctx_reset=true. Turning this OFF flushes anything
      still pending.
  - group_max_lines: how many lines one thread buffers before its box is
      closed and a fresh one starts. Lower = more responsive, more boxes.

  Not settable here: CFG_GROUP_TOTAL_CAP is a compile-time `::` constant. It's
  an out-of-memory guard, not a preference - edit it in private.odin if you
  really need to.

  ```odin
    import mn "libs/muninn"

    // typical: quiet console, everything on disk
    mn.init(level = .DEBUG, log_dir = "C:/logs/my_..."

    // structured output for a log shipper
    mn.init(emit_json = true, save_file = false)

    // debugging a thread pool
    mn.init(group_by_thread = true, group_max_lines = 25, show_tid = false)

    // console only, no files at all
    mn.init(save_file = false)

    // bump verbosity later, from anywhere, safely
    mn.init(level = .TRACE)
  ```
*/
init :: proc(
	level: Maybe(Levels) = nil,
	rotate_days: Maybe(int) = nil,
	//
	show_stack_trace: Maybe(bool) = nil,
	emit_json: Maybe(bool) = nil,
	use_color: Maybe(bool) = nil,
	show_location: Maybe(bool) = nil,
	short_location: Maybe(bool) = nil,
	show_runtime: Maybe(bool) = nil,
	show_timestamp: Maybe(bool) = nil,
	show_pid: Maybe(bool) = nil,
	show_tid: Maybe(bool) = nil,
	//
	group_max_lines: Maybe(int) = nil,
	group_by_thread: Maybe(bool) = nil,
	//
	log_dir: Maybe(string) = nil,
	save_file: Maybe(bool) = nil,
) {
	// ---------------------------------------------------------------- verbosity and rotation
	if v, ok := level.?; ok do set_log_level(v)
	if v, ok := rotate_days.?; ok do CFG_ROTATE_DAYS = max(0, v)

	// ----------------------------------------------------------------  pretty formatting
	if v, ok := show_stack_trace.?; ok do CFG_SHOW_STACK = v
	if v, ok := emit_json.?; ok do CFG_EMIT_JSON = v
	if v, ok := use_color.?; ok do CFG_USE_COLOR = v
	if v, ok := show_location.?; ok do CFG_SHOW_LOCATION = v
	if v, ok := short_location.?; ok do CFG_SHORT_LOCATION = v
	if v, ok := show_runtime.?; ok do CFG_SHOW_RUNTIME = v
	if v, ok := show_timestamp.?; ok do CFG_SHOW_TIMESTAMP = v
	if v, ok := show_pid.?; ok do CFG_SHOW_PID = v
	if v, ok := show_tid.?; ok do CFG_SHOW_TID = v

	// ----------------------------------------------------------------  grouping
	if v, ok := group_max_lines.?; ok do CFG_GROUP_MAX_LINES = max(1, v)
	if v, ok := group_by_thread.?; ok {
		if !v && CFG_GROUP_BY_THREAD do flush_now()
		CFG_GROUP_BY_THREAD = v
	}

	// ----------------------------------------------------------------  file sink
	want_dir, dir_given := log_dir.?
	save_given := false
	if v, ok := save_file.?; ok {
		CFG_SAVE_FILE = v
		save_given = true
	}

	if dir_given || save_given {
		sync.lock(&LOG_MUTEX)
		defer sync.unlock(&LOG_MUTEX)

		if dir_given && want_dir != CFG_LOG_DIR {
			rebuild_log_path_locked(want_dir)
		} else if CFG_SAVE_FILE && LOG_PATH == "" && CFG_LOG_DIR != "" {
			rebuild_log_path_locked(CFG_LOG_DIR)
		}
		reopen_file_locked()
	}
}


/***************************************************************************************************
 * [ Logging Core Funcs ]
***************************************************************************************************/

/*
is_enabled reports whether a level would actually be emitted. use it to skip
building expensive arguments in hot paths:

  ```odin
  if mn.enabled(.DEBUG) do mn.debug("state: %v", expensive_dump())
  ```
*/
is_enabled :: #force_inline proc "contextless" (lvl: Levels) -> bool {
	return lvl >= log_level()
}

// inlined formatting
@(private)
_fmt :: #force_inline proc(msg: string, args: []any) -> string {
	return msg if len(args) == 0 else fmt.tprintf(msg, ..args)
}

// inlined into each wrapper below for consistency
@(private)
_log :: #force_inline proc(
	lvl: Levels,
	tag, clr, msg: string,
	args: []any,
	ctx_reset, s_trace: bool,
	loc: runtime.Source_Code_Location,
) {
	if ctx_reset do group_reset()
	if lvl < log_level() do return
	central_log(tag, clr, _fmt(msg, args), loc, s_trace)
}

// alias, these for QOL
reset_ctx :: group_reset
warning :: warn

trace :: proc(msg: string, args: ..any, ctx_reset := false, location := #caller_location) {
	_log(.TRACE, "[ TRACE ]", GRAY, msg, args, ctx_reset, false, location)
}

debug :: proc(msg: string, args: ..any, ctx_reset := false, location := #caller_location) {
	_log(.DEBUG, "[ DEBUG ]", BLUE, msg, args, ctx_reset, false, location)
}

info :: proc(msg: string, args: ..any, ctx_reset := false, location := #caller_location) {
	_log(.INFO, "[ INFO  ]", GREEN, msg, args, ctx_reset, false, location)
}

warn :: proc(msg: string, args: ..any, ctx_reset := false, location := #caller_location) {
	_log(.WARN, "[ WARN  ]", YELLOW, msg, args, ctx_reset, false, location)
}

error :: proc(msg: string, args: ..any, ctx_reset := false, location := #caller_location) {
	_log(.ERROR, "[ ERROR ]", RED, msg, args, ctx_reset, true, location)
}

fatal :: proc(msg: string, args: ..any, ctx_reset := false, location := #caller_location) {
	if ctx_reset do group_reset()
	fmt_msg := _fmt(msg, args)
	central_log("[ FATAL ]", MAGENTA, fmt_msg, location, true)
	flush_now()
	panic(fmt_msg)
}

/*
sep prints a formatted line in console. Color can be a ANSII code OR on of the
following > ( mr.GRAY, BLUE, GREEN, YELLOW, RED, MAGENTA, CYAN )

Args:
  - char (optional): the chars to print (advise only len of 1)
  - color (optional): choose from: blue, gray, green, yellow, red, magenta, cyan
  - nl_pre (optional): add newline before
  - nl_post (optional): add newline after

  ```odin
  mn.sep(char="-", color=mr.RED, nl_pre=true, nl_post=true)
  mn.sep(char="-", color="\x1b[38;5;77m", nl_pre=true, nl_post=true)
  ```
*/
sep :: proc(
	char: string = "*",
	color: string = BLUE,
	nl_pre: bool = false,
	nl_post: bool = false,
) {
	backing: [1024]u8
	b := strings.builder_from_bytes(backing[:])

	if nl_pre do strings.write_byte(&b, '\n')
	if CFG_USE_COLOR do strings.write_string(&b, color)
	strings.write_string(&b, repeat(char))
	if CFG_USE_COLOR do strings.write_string(&b, RESET)
	strings.write_byte(&b, '\n')
	if nl_post do strings.write_byte(&b, '\n')

	// same lock as central_log so separators can't land mid-line
	sync.lock(&LOG_MUTEX)
	console_write(strings.to_string(b))
	sync.unlock(&LOG_MUTEX)
}

/*
title prints a newline, a formatted separator line, your message, and another
formatted separator line. Color can be a ANSII code OR on of the following >
( mr.GRAY, BLUE, GREEN, YELLOW, RED, MAGENTA, CYAN )

Args:
  - msg: Your title message - no formatting applied
  - char (optional): the character to use as a separator. default to '*'.
  - color (optional): defaults to BLUE


  ```odin
  import mn "libs/muninn"

  mr.title(msg="Some Title", char="-", color=mr.RED)
  mr.title(msg="Some Title", char="-", color="\x1b[38;5;77m")
  ```
*/
title :: proc(msg: string, char: string = "*", color: string = BLUE) {
	sep(char, color, nl_pre = true)
	m := fmt.tprintf("%s* [ %s ]%s", color, msg, RESET) if CFG_USE_COLOR else msg
	fmt.println(m)
	sep(char, color)
}

/***************************************************************************************************
 * [ Sanitation ]
***************************************************************************************************/

// flush buffered file output. call before a hard exit / os.exit().
// @(fini) already does this on a normal return from main.
flush :: proc() {
	flush_now()
}

/***************************************************************************************************
 * [ PRIVATE ]
 Everything below this line is private functions... This is so the public api stays stupid clear
 and causes minimal confusion as per what can be used or not.
***************************************************************************************************/


/***************************************************************************************************
 * [ Globals ]
***************************************************************************************************/

// containers
@(private)
USER: string

@(private)
STARTED := time.now()

@(private)
TRACE_CTX: trace.Context

@(private)
PROC_ID := os.get_pid()

@(private)
VERBOSE := false

@(private)
PROG_NAME: string

@(private)
GROUPS: map[int][dynamic]string

@(private)
GROUP_ORDER: [dynamic]int

@(private)
GROUP_ALLOC: runtime.Allocator

@(private)
GROUP_COUNT: int

@(private)
EDITING_FILE: ^os.File

// locks
@(private)
LOG_MUTEX: sync.Mutex

@(private)
TIME_MUTEX: sync.Mutex

@(private)
TRACE_MUTEX: sync.Mutex

@(private)
INIT_ONCE: sync.Once

// file write buffering
@(private)
FILE_BUF: strings.Builder

@(private)
FLUSH_AT :: 32 * 1024

@(private)
LINE_CAP :: 4096

// space held back inside LINE_CAP so the JSON tail
// (`"stack":[]` + `,"truncated":true` + `}`) is always writable
@(private)
TAIL_RESERVE :: 48

@(private)
MSG_CAP :: 2048

// options: saving
@(private)
LOG_PATH: string

@(private)
CFG_SAVE_FILE := true

@(private)
CFG_LOG_DIR: string

@(private)
CFG_ROTATE_DAYS := 5

// options
@(private)
CFG_LOG_LVL := Levels.INFO

@(private)
CFG_USE_COLOR := true

@(private)
CFG_SHOW_LOCATION := true

@(private)
CFG_SHORT_LOCATION := true

@(private)
CFG_SHOW_RUNTIME := true

@(private)
CFG_SHOW_TIMESTAMP := true

@(private)
CFG_SHOW_PID := false

@(private)
CFG_SHOW_TID := false

@(private)
CFG_SHOW_STACK := true

@(private)
CFG_EMIT_JSON := false

// groups - guarded by LOG_MUTEX
@(private)
CFG_GROUP_TOTAL_CAP :: 50_000 // oh shit cap!

@(private)
CFG_GROUP_BY_THREAD := false

@(private)
CFG_GROUP_MAX_LINES := 50 // per-thread (or job context) rolling lins printed in frame

@(private)
log_level :: #force_inline proc "contextless" () -> Levels {
	return Levels(intrinsics.atomic_load((^i32)(&CFG_LOG_LVL)))
}

@(private)
set_log_level :: #force_inline proc "contextless" (l: Levels) {
	intrinsics.atomic_store((^i32)(&CFG_LOG_LVL), i32(l))
}

@(thread_local)
@(private)TID_CACHE: int

@(private)
thread_id :: proc() -> int {
	if TID_CACHE == 0 {
		TID_CACHE = sync.current_thread_id()
	}
	return TID_CACHE
}

@(private)
console_write :: #force_inline proc(s: string) {
	os.write_string(os.stdout, s)
}

/***************************************************************************************************
 * [ Init ]
***************************************************************************************************/
@(init)
@(private)
_init :: proc() {
	// Turns on UTF-8 output + ANSI escape handling on Windows
	when ODIN_OS == .Windows {
		SetConsoleOutputCP(CP_UTF8)
		h := GetStdHandle(STD_OUTPUT_HANDLE)
		mode: u32
		if GetConsoleMode(h, &mode) {
			SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING)
		}
	}

	// set logged in username
	when ODIN_OS == .Windows {
		USER, _ = get_env_string("USERNAME")
	} else {
		USER, _ = get_env_string("USER")
	}

	// default log location
	if CFG_SAVE_FILE {
		f, err := os.get_executable_path(context.allocator)
		if err != nil {
			PROG_NAME = "Unknown"
		}
		defer delete(f)

		dir, name := filepath.split(f)
		if i := strings.last_index_byte(name, '.'); i >= 0 {
			name = name[:i]
		}
		ld, _ := filepath.join({dir, ".logs"})
		if CFG_LOG_DIR != "" do delete(CFG_LOG_DIR)
		CFG_LOG_DIR = strings.clone(ld)

		if PROG_NAME != "" do delete(PROG_NAME)
		PROG_NAME = strings.clone(name)

		ts_buf: [64]u8
		fn := fmt.tprintf("%s__%s.jsonl", PROG_NAME, timestamp(ts_buf[:], true))
		lp, _ := filepath.join({CFG_LOG_DIR, fn})
		LOG_PATH = strings.clone(lp)
		os.make_directory_all(CFG_LOG_DIR)
	} else {
		fmt.println("Unable to set log directory, please manually set path with init()")
	}

	// color use
	no_color := env_is_set("NO_COLOR")
	force_color := env_is_set("FORCE_COLOR")
	force_no_color := env_is_set("FORCE_NO_COLOR")
	CFG_USE_COLOR = (!force_no_color && !no_color) || force_color

	if os.exists("muninn.verbose.lock") {
		set_log_level(.TRACE)
		VERBOSE = true
	} else {
		if v, ok := get_env_string("LOG_LEVEL"); ok && len(v) > 0 {
			set_level(v)
		}
	}

	// trace if in debug
	when ODIN_DEBUG {
		ok := trace.init(&TRACE_CTX)
		if VERBOSE do fmt.printfln("> trace init set? %v", ok)
	}
}


/***************************************************************************************************
 * [ Exit ]
***************************************************************************************************/
@(fini)
@(private)
cleanup :: proc() {
	sync.lock(&LOG_MUTEX)
	group_flush_locked() // dump any pending thread boxes first
	flush_locked()
	if EDITING_FILE != nil {
		os.close(EDITING_FILE)
		EDITING_FILE = nil
	}
	strings.builder_destroy(&FILE_BUF)
	delete(GROUPS)
	delete(GROUP_ORDER)
	sync.unlock(&LOG_MUTEX)

	when ODIN_DEBUG {
		trace.destroy(&TRACE_CTX)
	}

	// log rotation
	if !CFG_SAVE_FILE || CFG_LOG_DIR == "" do return

	prefix := fmt.tprintf("%s__", PROG_NAME)
	safe := make([dynamic]string, 0, CFG_ROTATE_DAYS + 1)
	for i in 0 ..< CFG_ROTATE_DAYS {
		ts_buf: [64]u8
		append(&safe, fmt.tprintf("%s%s.jsonl", prefix, timestamp(ts_buf[:], true, i)))
	}

	files, err := os.read_directory_by_path(CFG_LOG_DIR, -1, context.allocator)
	if err != nil do return
	defer delete(files)

	for f in files {
		if f.type == .Directory do continue
		if f.fullpath == LOG_PATH do continue
		if !strings.has_prefix(f.name, prefix) do continue
		if !strings.has_suffix(f.name, ".jsonl") do continue
		if !slice.contains(safe[:], f.name) do os.remove(f.fullpath)
	}
}

// caller MUST hold LOG_MUTEX
@(private)
flush_locked :: proc() {
	if EDITING_FILE == nil do return
	if strings.builder_len(FILE_BUF) == 0 do return
	os.write_string(EDITING_FILE, strings.to_string(FILE_BUF))
	strings.builder_reset(&FILE_BUF)
}

@(private)
flush_now :: proc() {
	sync.lock(&LOG_MUTEX)
	group_flush_locked()
	flush_locked()
	sync.unlock(&LOG_MUTEX)
}

/***************************************************************************************************
 * [ Main logging ]
***************************************************************************************************/
@(private)
central_log :: proc(
	lvl, clr, msg: string,
	loc: runtime.Source_Code_Location,
	s_trace: bool = false,
) {
	sync.once_do(&INIT_ONCE, validate_requirements)

	// redeclare for thread safety
	save := CFG_SAVE_FILE
	emit := CFG_EMIT_JSON
	color := CFG_USE_COLOR
	tid := thread_id()

	ts_buf: [64]u8
	ts: string
	if CFG_SHOW_TIMESTAMP do ts = timestamp(ts_buf[:])

	rt_buf: [time.MIN_HMS_LEN]u8
	rt: string
	if CFG_SHOW_RUNTIME do rt = time.to_string_hms(time.since(STARTED), rt_buf[:])

	fpath, fname, func: string
	line, col: int
	if CFG_SHOW_LOCATION {
		fpath = loc.file_path
		_, fname = filepath.split(loc.file_path)
		line = int(loc.line)
		col = int(loc.column)
		func = loc.procedure
	}

	fmt_st: string
	vec_st: []string
	if s_trace {
		sync.lock(&TRACE_MUTEX)
		fmt_st, vec_st = get_trace()
		sync.unlock(&TRACE_MUTEX)
	}

	bare := strings.trim_space(strings.trim_right(strings.trim_left(lvl, "["), "]"))

	// build json
	json_backing: [LINE_CAP]u8 = ---
	json_line: string
	if save || emit {
		jb := strings.builder_from_bytes(json_backing[:])
		w := jw_begin(&jb, LINE_CAP)
		jw_str(&w, "level", bare)
		jw_str(&w, "timestamp", ts)
		jw_str(&w, "runtime", rt)
		jw_str(&w, "user", USER)
		jw_str(&w, "file", fpath)
		jw_int(&w, "process_id", PROC_ID)
		jw_int(&w, "thread_id", tid)
		jw_str(&w, "procedure", func)
		jw_int(&w, "line", line)
		jw_int(&w, "column", col)
		jw_str(&w, "message", msg)
		jw_stack(&w, vec_st) // must stay last
		json_line = jw_end(&w)
	}

	// build pretty
	line_backing: [LINE_CAP]u8 = ---
	pretty: string
	if !emit {
		lb := strings.builder_from_bytes(line_backing[:])

		if ts != "" {
			strings.write_string(&lb, "[ ")
			strings.write_string(&lb, ts)
			strings.write_string(&lb, " ]")
		}
		if rt != "" {
			strings.write_string(&lb, "[ ")
			strings.write_string(&lb, rt)
			strings.write_string(&lb, " ]")
		}

		if color do strings.write_string(&lb, clr)
		strings.write_string(&lb, lvl)
		if color do strings.write_string(&lb, RESET)

		strings.write_byte(&lb, ' ')
		strings.write_string(&lb, clamp_str(msg, MSG_CAP))

		if CFG_SHOW_LOCATION {
			if color do strings.write_string(&lb, GRAY)
			strings.write_string(&lb, " > ")
			strings.write_string(&lb, fname if CFG_SHORT_LOCATION else fpath)
			strings.write_byte(&lb, ':')
			strings.write_int(&lb, line)
			strings.write_string(&lb, " ( ")
			strings.write_string(&lb, func)
			strings.write_string(&lb, " )")
			if color do strings.write_string(&lb, RESET)
		}

		if CFG_SHOW_PID || CFG_SHOW_TID {
			if color do strings.write_string(&lb, GRAY)
			strings.write_string(&lb, " :: ( ")
			if CFG_SHOW_PID {
				strings.write_string(&lb, "process_id = ")
				strings.write_int(&lb, PROC_ID)
			}
			if CFG_SHOW_PID && CFG_SHOW_TID do strings.write_string(&lb, " | ")
			if CFG_SHOW_TID {
				strings.write_string(&lb, "thread_id = ")
				strings.write_int(&lb, tid)
			}
			strings.write_string(&lb, " )")
			if color do strings.write_string(&lb, RESET)
		}

		strings.write_string(&lb, fmt_st)
		strings.write_byte(&lb, '\n')
		pretty = strings.to_string(lb)
	}

	// lock and write all
	sync.lock(&LOG_MUTEX)
	if save && EDITING_FILE != nil {
		strings.write_string(&FILE_BUF, json_line)
		strings.write_byte(&FILE_BUF, '\n')
		if s_trace || strings.builder_len(FILE_BUF) >= FLUSH_AT {
			flush_locked()
		}
	}

	if emit {
		console_write(json_line)
		console_write("\n")
	} else if CFG_GROUP_BY_THREAD {
		group_push_locked(tid, pretty)
	} else {
		console_write(pretty)
	}
	sync.unlock(&LOG_MUTEX)
}

/***************************************************************************************************
 * [ Thread grouping ]
***************************************************************************************************/
// caller must hold LOG_MUTEX
@(private)
group_push_locked :: proc(tid: int, line: string) {
	bucket, seen := GROUPS[tid]
	if !seen {
		bucket = make([dynamic]string, 0, 64, GROUP_ALLOC)
		append(&GROUP_ORDER, tid)
	}

	// stack traces arrive with embedded newlines - one row each or the box tears
	for seg in strings.split(strings.trim_right(line, "\n"), "\n") {
		append(&bucket, strings.clone(seg, GROUP_ALLOC))
		GROUP_COUNT += 1
	}
	GROUPS[tid] = bucket // write the possibly-grown header back
	if len(bucket) >= CFG_GROUP_MAX_LINES do group_close_one_locked(tid)

	// global: hard ceiling, dumps everything
	if GROUP_COUNT >= CFG_GROUP_TOTAL_CAP do group_flush_locked()
}

// caller must hold LOG_MUTEX
@(private)
group_close_one_locked :: proc(tid: int) {
	lines, ok := GROUPS[tid]
	if !ok do return

	group_box_locked(tid, lines[:])

	GROUP_COUNT -= len(lines)
	for s in lines do delete(s, GROUP_ALLOC)
	delete(lines)
	delete_key(&GROUPS, tid)

	// drop it from the order list so a re-seen tid appends at the back
	for t, i in GROUP_ORDER {
		if t == tid {
			ordered_remove(&GROUP_ORDER, i)
			break
		}
	}
}

// caller must hold LOG_MUTEX
@(private)
group_flush_locked :: proc() {
	for tid in GROUP_ORDER {
		lines, ok := GROUPS[tid]
		if !ok do continue
		group_box_locked(tid, lines[:])
		for s in lines do delete(s, GROUP_ALLOC)
		delete(lines)
	}
	clear(&GROUPS)
	clear(&GROUP_ORDER)
	GROUP_COUNT = 0
}

// caller must hold LOG_MUTEX
@(private)
group_box_locked :: proc(tid: int, lines: []string) {
	if len(lines) == 0 do return

	label := fmt.tprintf("[ thread_id = %d ]", tid)

	tw := get_term_width()
	if tw <= 0 do tw = 120

	widths := make([dynamic]int, 0, len(lines))
	max_len := 0
	for s in lines {
		w := ansi_width(s)
		append(&widths, w)
		if w > max_len do max_len = w
	}

	inner := max_len + 2
	inner = min(inner, tw - 2)
	inner = max(inner, len(label) + 2)

	bc :: proc(s: string) -> string {
		return fmt.tprintf("%s%s%s", BLUE, s, RESET) if CFG_USE_COLOR else s
	}

	sb := strings.builder_make()

	// top: label cut into the frame
	fill := strings.repeat("═", inner - 1 - len(label))
	fmt.sbprintf(&sb, "%s\n", bc(fmt.tprintf("╔═%s%s╗", label, fill)))

	// body
	for s, i in lines {
		body, vis := s, widths[i]
		if vis > inner - 1 {
			body = ansi_truncate(s, inner - 1)
			vis = inner - 1
		}
		gap := strings.repeat(" ", inner - 1 - vis)
		fmt.sbprintf(&sb, "%s %s%s%s\n", bc("║"), body, gap, bc("║"))
	}

	// bottom
	fmt.sbprintf(&sb, "%s\n", bc(fmt.tprintf("╚%s╝", strings.repeat("═", inner))))

	console_write(strings.to_string(sb))
}

// closes this thread's pending box, if any
group_reset :: proc() {
	if !CFG_GROUP_BY_THREAD do return
	tid := thread_id()
	sync.lock(&LOG_MUTEX)
	group_close_one_locked(tid)
	sync.unlock(&LOG_MUTEX)
}

/***************************************************************************************************
 * [ JSON writers ]
***************************************************************************************************/
/*
The JSON line is built into a fixed LINE_CAP stack buffer whose builder has a
nil allocator - writes past capacity fail SILENTLY. Left unguarded that yields a
half-written line with no closing brace, i.e. a corrupt .jsonl that breaks every
downstream parser for the whole file.

So every write goes through J_Writer, which tracks a budget of
LINE_CAP - TAIL_RESERVE. TAIL_RESERVE is the physical space held back so that
`"stack":[]` + `,"truncated":true` + `}` is ALWAYS writable no matter what came
before. Values are cut at rune boundaries, and anything cut sets .trunc, which
surfaces as "truncated":true on the line itself.
*/

@(private)
J_Writer :: struct {
	b:     ^strings.Builder,
	limit: int,
	trunc: bool,
}

@(rodata)
@(private)
HEX_DIGITS := "0123456789abcdef"

// writes the opening brace and returns a writer budgeted to cap_bytes
@(private)
jw_begin :: proc(b: ^strings.Builder, cap_bytes: int) -> J_Writer {
	strings.write_byte(b, '{')
	return J_Writer{b = b, limit = cap_bytes - TAIL_RESERVE}
}

@(private)
jw_left :: proc(w: ^J_Writer) -> int {
	return w.limit - strings.builder_len(w.b^)
}

// bytes this char occupies once escaped
@(private)
esc_len :: proc(c: u8) -> int {
	switch c {
	case '"', '\\', '\n', '\r', '\t':
		return 2
	}
	if c < 0x20 do return 6
	return 1
}

@(private)
esc_byte :: proc(b: ^strings.Builder, c: u8) {
	switch c {
	case '"':
		strings.write_string(b, `\"`)
	case '\\':
		strings.write_string(b, `\\`)
	case '\n':
		strings.write_string(b, `\n`)
	case '\r':
		strings.write_string(b, `\r`)
	case '\t':
		strings.write_string(b, `\t`)
	case:
		if c < 0x20 {
			strings.write_string(b, `\u00`)
			strings.write_byte(b, HEX_DIGITS[c >> 4])
			strings.write_byte(b, HEX_DIGITS[c & 0xF])
		} else {
			strings.write_byte(b, c)
		}
	}
}

// escapes val into w, stopping on the last whole rune that fits.
// reserve = bytes the caller still needs after this (closing quote, comma...).
@(private)
jw_esc_capped :: proc(w: ^J_Writer, val: string, reserve: int) -> bool {
	budget := jw_left(w) - reserve
	if budget < 0 do budget = 0

	used, i := 0, 0
	for i < len(val) {
		// measure a whole rune so a multi-byte char is never split
		n := 1
		for i + n < len(val) && (val[i + n] & 0xC0) == 0x80 do n += 1

		cost := 0
		for k in 0 ..< n do cost += esc_len(val[i + k])
		if used + cost > budget {
			w.trunc = true
			return false
		}
		for k in 0 ..< n do esc_byte(w.b, val[i + k])
		used += cost
		i += n
	}
	return true
}

@(private)
jw_str :: proc(w: ^J_Writer, key, val: string) {
	// `"` + key + `":"` + `",`
	if jw_left(w) < len(key) + 6 {
		w.trunc = true
		return
	}
	strings.write_byte(w.b, '"')
	strings.write_string(w.b, key)
	strings.write_string(w.b, `":"`)
	jw_esc_capped(w, val, 2)
	strings.write_string(w.b, `",`)
}

@(private)
jw_int :: proc(w: ^J_Writer, key: string, val: int) {
	// key + quotes + colon + comma + room for a 64-bit decimal
	if jw_left(w) < len(key) + 25 {
		w.trunc = true
		return
	}
	strings.write_byte(w.b, '"')
	strings.write_string(w.b, key)
	strings.write_string(w.b, `":`)
	strings.write_int(w.b, val)
	strings.write_byte(w.b, ',')
}

// must be the LAST field written - it closes without a trailing comma
@(private)
jw_stack :: proc(w: ^J_Writer, frames: []string) {
	strings.write_string(w.b, `"stack":[`)
	wrote := 0
	for f in frames {
		lead := 0
		if wrote > 0 do lead = 1
		if jw_left(w) < lead + 3 {
			w.trunc = true
			break
		}
		if wrote > 0 do strings.write_byte(w.b, ',')
		strings.write_byte(w.b, '"')
		ok := jw_esc_capped(w, f, 1)
		strings.write_byte(w.b, '"')
		wrote += 1
		if !ok do break
	}
	strings.write_byte(w.b, ']')
}

@(private)
jw_end :: proc(w: ^J_Writer) -> string {
	if w.trunc do strings.write_string(w.b, `,"truncated":true`)
	strings.write_byte(w.b, '}')
	return strings.to_string(w.b^)
}

/***************************************************************************************************
 * [ Stack trace ]
***************************************************************************************************/
@(private)
TRACE_HEAD :: 5

@(private)
TRACE_TAIL :: 5

@(private)
TRACE_MAX :: TRACE_HEAD + TRACE_TAIL

@(private)
TRUNC_MARK :: "... [ TRUNCATED SEE LOGS FOR FULL TRACE ] ..."

// caller must hold TRACE_MUTEX
@(private)
get_trace :: proc() -> (string, []string) {
	when !ODIN_DEBUG do return "", nil
	if !CFG_SHOW_STACK do return "", nil

	vec := make([dynamic]string, 0, 16)
	buf: [64]trace.Frame
	frames := trace.frames(&TRACE_CTX, 3, buf[:])

	Row :: struct {
		arm:   string,
		rest:  string,
		depth: int,
		clr:   string,
	}
	rows := make([dynamic]Row, 0, 16)

	is_src := true
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	for f in frames {
		fl := trace.resolve(&TRACE_CTX, f, context.temp_allocator)
		if fl.loc.file_path == "" do continue

		arm := "SRC! > " if is_src else "FROM > "
		is_src = false

		append(
			&rows,
			Row {
				arm = arm,
				rest = fmt.tprintf("%s:%d %s", fl.loc.file_path, fl.loc.line, fl.loc.procedure),
				clr = RED,
			},
		)
		append(&vec, fmt.tprintf("%s:%d > %s", fl.loc.file_path, fl.loc.line, fl.loc.procedure))
	}

	// collapse the middle of both so were not blowing anything out
	if len(vec) > TRACE_MAX {
		trimmed := make([dynamic]string, 0, TRACE_MAX + 1)
		append(&trimmed, ..vec[:TRACE_HEAD])
		append(&trimmed, TRUNC_MARK)
		append(&trimmed, ..vec[len(vec) - TRACE_TAIL:])
		vec = trimmed
	}

	if len(rows) == 0 do return "", vec[:]
	if len(rows) > 1 do rows[len(rows) - 1].arm = "LAST > "

	shown := rows
	if len(rows) > TRACE_MAX {
		shown = make([dynamic]Row, 0, TRACE_MAX + 1)
		append(&shown, ..rows[:TRACE_HEAD])
		append(&shown, Row{rest = TRUNC_MARK, clr = YELLOW})
		append(&shown, ..rows[len(rows) - TRACE_TAIL:])
	}
	truncated := len(shown) != len(rows)

	// head walks in, marker is the deepest thing on screen, tail walks back
	for &r, i in shown {
		if !truncated {
			r.depth = i
		} else {
			switch {
			case i < TRACE_HEAD:
				r.depth = i
			case i == TRACE_HEAD:
				r.depth = TRACE_HEAD
			case:
				r.depth = len(shown) - 1 - i
			}
		}
	}

	// width has to be measured on the final indents, post-splice
	texts := make([dynamic]string, 0, len(shown))
	max_len := 0
	for r in shown {
		pad := strings.repeat(" ", r.depth * 2)
		t := fmt.tprintf("%s%s%s", pad, r.arm, r.rest)
		append(&texts, t)
		if len(t) > max_len do max_len = len(t)
	}

	inner := max_len + 2
	sb := strings.builder_make()

	c :: proc(s: string) -> string {
		return fmt.tprintf("%s%s%s", RED, s, RESET) if CFG_USE_COLOR else s
	}

	// top
	fmt.sbprintf(&sb, "\n%s", c(fmt.tprintf("╔%s╗", strings.repeat("═", inner))))

	// body
	for r, i in shown {
		plain := texts[i]
		body := plain
		if CFG_USE_COLOR {
			pad := strings.repeat(" ", r.depth * 2)
			if r.arm == "" {
				body = fmt.tprintf("%s%s%s%s", pad, r.clr, r.rest, RESET)
			} else {
				body = fmt.tprintf("%s%s%s%s%s", pad, r.clr, r.arm, RESET, r.rest)
			}
		}
		gap := strings.repeat(" ", max(0, inner - 1 - len(plain)))
		fmt.sbprintf(&sb, "\n%s %s%s%s", c("║"), body, gap, c("║"))
	}

	// bottom
	fmt.sbprintf(&sb, "\n%s", c(fmt.tprintf("╚%s╝", strings.repeat("═", inner))))

	return strings.to_string(sb), vec[:]
}

/***************************************************************************************************
 * [ Helpers ]
***************************************************************************************************/

// truncate to at most n bytes without splitting a rune
@(private)
clamp_str :: proc(s: string, n: int) -> string {
	if len(s) <= n do return s
	end := n
	for end > 0 && (s[end] & 0xC0) == 0x80 do end -= 1
	return s[:end]
}

// visible rune count, skipping CSI sequences
@(private)
ansi_width :: proc(s: string) -> int {
	n, i := 0, 0
	for i < len(s) {
		if s[i] == 0x1b {
			i += 1
			if i < len(s) && s[i] == '[' {
				i += 1
				for i < len(s) && !(s[i] >= 0x40 && s[i] <= 0x7e) do i += 1
				if i < len(s) do i += 1
			}
			continue
		}
		if s[i] & 0xc0 != 0x80 do n += 1 // utf8 lead bytes only
		i += 1
	}
	return n
}

// clip to max_vis visible runes, passing escapes through untouched
@(private)
ansi_truncate :: proc(s: string, max_vis: int) -> string {
	b := strings.builder_make()
	n, i := 0, 0
	for i < len(s) {
		if s[i] == 0x1b {
			start := i
			i += 1
			if i < len(s) && s[i] == '[' {
				i += 1
				for i < len(s) && !(s[i] >= 0x40 && s[i] <= 0x7e) do i += 1
				if i < len(s) do i += 1
			}
			strings.write_string(&b, s[start:i])
			continue
		}
		if s[i] & 0xc0 != 0x80 {
			if n >= max_vis - 1 do break
			n += 1
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	strings.write_rune(&b, '…')
	if CFG_USE_COLOR do strings.write_string(&b, RESET)
	return strings.to_string(b)
}

@(private)
set_level :: proc(value: any) {
	switch v in value {
	case string:
		up := strings.to_upper(strings.trim_space(v))
		switch up {
		case "TRACE":
			set_log_level(.TRACE)
		case "DEBUG":
			set_log_level(.DEBUG)
		case "INFO":
			set_log_level(.INFO)
		case "WARN", "WARNING":
			set_log_level(.WARN)
		case "ERROR":
			set_log_level(.ERROR)
		case "FATAL":
			set_log_level(.FATAL)
		case:
			set_log_level(.INFO)
		}
	case:
		n, ok := reflect.as_i64(value)
		if !ok {
			set_log_level(.INFO)
			return
		}
		switch {
		case n < 10:
			set_log_level(.TRACE)
		case n < 20:
			set_log_level(.DEBUG)
		case n < 30:
			set_log_level(.INFO)
		case n < 40:
			set_log_level(.WARN)
		case n < 50:
			set_log_level(.ERROR)
		case:
			set_log_level(.FATAL)
		}
	}
}

@(private)
timestamp :: proc(buf: []u8, is_for_file: bool = false, offset: int = 0) -> string {
	t := libc.time(nil)
	if offset > 0 && is_for_file {
		t -= libc.time_t(offset * 24 * 60 * 60)
	}

	sync.lock(&TIME_MUTEX)
	defer sync.unlock(&TIME_MUTEX)

	tm := libc.localtime(&t)
	n: uint
	if is_for_file {
		n = libc.strftime(raw_data(buf), len(buf), "%Y-%m-%d", tm)
	} else {
		n = libc.strftime(raw_data(buf), len(buf), "%Y-%m-%d %H:%M:%S", tm)
	}

	return string(buf[:n])
}

@(private)
validate_requirements :: proc() {
	GROUP_ALLOC = context.allocator
	GROUPS = make(map[int][dynamic]string, 8, GROUP_ALLOC)
	GROUP_ORDER = make([dynamic]int, 0, 8, GROUP_ALLOC)

	if VERBOSE do fmt.printfln("> save file? %t", CFG_SAVE_FILE)
	if CFG_SAVE_FILE {
		if VERBOSE do fmt.printfln("> log dir? %s", CFG_LOG_DIR)
		if CFG_LOG_DIR == "" {
			panic("Log directory not set, please manually set with init()")
		}

		if VERBOSE do fmt.printfln("> log path? %s", LOG_PATH)
		if LOG_PATH == "" {
			panic("Log path did not get set, please manually set with init()")
		}

		if EDITING_FILE == nil {
			ef, err := os.open(LOG_PATH, {.Write, .Create, .Append})
			if err != nil {
				fmt.println(err)
				panic(
					fmt.tprintf(
						"Unable to create logs in %s, please manually set with init()",
						CFG_LOG_DIR,
					),
				)
			}
			EDITING_FILE = ef
			strings.builder_init(&FILE_BUF, 0, FLUSH_AT + LINE_CAP)
		}
		if VERBOSE do fmt.printfln("> editing file is nil? %t", EDITING_FILE == nil)
	}

	if VERBOSE do fmt.printfln("> is valid? %t", true)
	if VERBOSE do sep(color = GRAY)
}

@(private)
repeat :: proc(char: string, i: int = 0) -> string {
	i := i if i > 0 else get_term_width()
	return strings.repeat(char, i)
}

/***************************************************************************************************
 * [ used for manual init ]
***************************************************************************************************/

// caller must hold LOG_MUTEX
// swaps the log directory and derives a fresh PROG__DATE.jsonl path from it
@(private)
rebuild_log_path_locked :: proc(fpath: string) {
	dir, name := filepath.split(fpath)
	os.make_directory_all(dir)

	if CFG_LOG_DIR != "" do delete(CFG_LOG_DIR)
	if LOG_PATH != "" do delete(LOG_PATH)

	CFG_LOG_DIR = dir
	LOG_PATH = strings.clone(fpath)
}

// caller must hold LOG_MUTEX
// idempotent: closes whatever's open, reopens only if we should be saving
@(private)
reopen_file_locked :: proc() {
	flush_locked()
	if EDITING_FILE != nil {
		os.close(EDITING_FILE)
		EDITING_FILE = nil
	}
	if !CFG_SAVE_FILE || LOG_PATH == "" do return

	ef, err := os.open(LOG_PATH, {.Write, .Create, .Append})
	if err != nil {
		fmt.println(err)
		return
	}
	EDITING_FILE = ef
	if cap(FILE_BUF.buf) == 0 {
		strings.builder_init(&FILE_BUF, 0, FLUSH_AT + LINE_CAP)
	}
}

/***************************************************************************************************
 * [ Platform bindings ]
***************************************************************************************************/
when ODIN_OS == .Windows {

	foreign import kernel32 "system:Kernel32.lib"

	@(private)
	HANDLE :: rawptr

	@(private)
	COORD :: struct {
		X, Y: i16,
	}

	@(private)
	SMALL_RECT :: struct {
		Left, Top, Right, Bottom: i16,
	}

	@(private)
	CONSOLE_SCREEN_BUFFER_INFO :: struct {
		dwSize:              COORD,
		dwCursorPosition:    COORD,
		wAttributes:         u16,
		srWindow:            SMALL_RECT,
		dwMaximumWindowSize: COORD,
	}

	@(private)
	STD_OUTPUT_HANDLE :: ~u32(0) - 10 // (DWORD)-11

	@(private)
	CP_UTF8 :: u32(65001)

	@(private)
	ENABLE_VIRTUAL_TERMINAL_PROCESSING :: u32(0x0004)

	@(private, default_calling_convention = "system")
	foreign kernel32 {
		GetStdHandle :: proc(nStdHandle: u32) -> HANDLE ---
		GetConsoleScreenBufferInfo :: proc(h: HANDLE, info: ^CONSOLE_SCREEN_BUFFER_INFO) -> b32 ---
		GetConsoleMode :: proc(h: HANDLE, mode: ^u32) -> b32 ---
		SetConsoleMode :: proc(h: HANDLE, mode: u32) -> b32 ---
		SetConsoleOutputCP :: proc(cp: u32) -> b32 ---
	}

} else when ODIN_OS ==
	.Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {

	foreign import libc "system:c"

	@(private)
	winsize :: struct {
		ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
	}
	@(private)
	TIOCGWINSZ :: c.ulong(0x5413) when ODIN_OS == .Linux else c.ulong(0x40087468)

	@(private)
	foreign libc {
		ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
	}
}

@(private)
DEFAULT_WIDTH :: 80

@(private)
// Width of stdout in columns. Falls back to DEFAULT_WIDTH when not a tty
// or on unsupported platforms.
get_term_width :: proc() -> int {
	when ODIN_OS == .Windows {
		info: CONSOLE_SCREEN_BUFFER_INFO
		if !GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &info) {
			return DEFAULT_WIDTH
		}
		w := int(info.srWindow.Right - info.srWindow.Left + 1)
		return w if w > 0 else DEFAULT_WIDTH
	} else when ODIN_OS ==
		.Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		ws: winsize
		if ioctl(1, TIOCGWINSZ, &ws) != 0 {
			return DEFAULT_WIDTH
		}
		return int(ws.ws_col) if ws.ws_col > 0 else DEFAULT_WIDTH
	} else {
		return DEFAULT_WIDTH
	}
}

@(private)
// check if var exists return bool for it
env_is_set :: proc(key: string) -> bool {
	buf: [64]u8
	v, err := os.lookup_env(buf[:], key)
	return err == nil && len(v) > 0
}

@(private)
// get a var and return an owned string
get_env_string :: proc(tgt: string, allocator := context.allocator) -> (string, bool) {
	v, found := os.lookup_env(tgt, allocator)
	if !found || len(v) == 0 {
		delete(v, allocator)
		return "", false
	}
	return v, true
}
