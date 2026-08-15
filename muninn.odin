#+feature global-context
package muninn

import "base:intrinsics"
import "base:runtime"
import "core:c"
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


// Muninn-v2026.08.004
/***************************************************************************************************
 * [ STATIC ]
***************************************************************************************************/
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


// These are memory / layout limits, changing them means recompiling and knowing why.
@(private)
FLUSH_AT :: 32 * 1024 // file buffer size before it is written out

@(private)
LINE_CAP :: 4096 // hard ceiling on one formatted json line

@(private)
MSG_CAP :: 2048 // hard ceiling on one message body

// space held back inside LINE_CAP so the JSON tail
// (`"stack":[]` + `,"truncated":true` + `}`) is always writable
@(private)
TAIL_RESERVE :: 48

@(private)
DEFAULT_WIDTH :: 80 // terminal width assumed when stdout is not a tty

/***************************************************************************************************
 * [ Globals ]
***************************************************************************************************/
/*
Config holds every knob a user can turn. Defaults below are what you get if you
never call init(). One struct, one place to look - init() just writes into it.
*/
@(private)
Config :: struct {
	// verbosity - level is read atomically, keep it first for alignment
	level:                Levels,
	verbose:              bool,

	// output routing
	save_file:            bool,
	log_dir:              string,
	rotate_days:          int,
	emit_json:            bool,

	// pretty formatting
	use_color:            bool,
	show_location:        bool,
	show_func:            bool,
	short_location:       bool,
	show_runtime:         bool,
	show_timestamp:       bool,
	show_pid:             bool,
	show_tid:             bool,
	show_stack:           bool,
	truncate_long_lines:  bool,

	// thread / job grouping
	group_by_thread:      bool,
	group_max_lines:      int,
	grouped_logs_stream:  bool,
	force_box_term_width: bool,
}

@(private)
CFG := Config {
	level                = .INFO,
	verbose              = false,
	save_file            = true,
	rotate_days          = 5,
	emit_json            = false,
	use_color            = true,
	show_location        = true,
	show_func            = true,
	short_location       = true,
	show_runtime         = true,
	show_timestamp       = true,
	show_pid             = false,
	show_tid             = false,
	show_stack           = true,
	truncate_long_lines  = true,
	group_by_thread      = false,
	group_max_lines      = 50,
	grouped_logs_stream  = true,
	force_box_term_width = false,
}

/*
State is everything the logger owns at runtime - handles, buffers, the open
group window, locks. Nothing in here is a setting, do not reach in from
outside the package.
*/
@(private)
State :: struct {
  self_loc:     string,
  rel_loc:      string,

	// process identity
	user:         string,
	prog_name:    string,
	started:      time.Time,
	proc_id:      int,

	// file sink
	log_path:     string,
	editing_file: ^os.File,
	file_buf:     strings.Builder,

	// grouping window
	group_tid:    int, // thread that owns the window, -1 = empty
	group_win:    [dynamic]string, // rows, oldest first

	// the logger's own allocator for anything that outlives a single call.
	// deliberately NOT context.allocator: init() can be called from inside an
	// arena or a scoped allocator, and whatever frees these later would then be
	// handing a foreign pointer to the wrong allocator.
	alloc:        runtime.Allocator,

	// stack traces
	trace_ctx:    trace.Context,

	// locks
	log_mutex:    sync.Mutex,
	time_mutex:   sync.Mutex,
	trace_mutex:  sync.Mutex,
	init_once:    sync.Once,
}

@(private)
ST := State {
  self_loc  = #directory,
  rel_loc   = "",
	started   = time.now(),
	proc_id   = os.get_pid(),
	group_tid = -1,
	alloc     = runtime.heap_allocator(),
}


@(private)
log_level :: #force_inline proc "contextless" () -> Levels {
	return Levels(intrinsics.atomic_load((^i32)(&CFG.level)))
}

@(private)
set_log_level :: #force_inline proc "contextless" (l: Levels) {
	intrinsics.atomic_store((^i32)(&CFG.level), i32(l))
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
 * [ Auto Init ]
***************************************************************************************************/
@(init)
@(private)
_init :: proc() {
	// Turns on UTF-8 output + ANSI escape handling on !stupid! Windows
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
		ST.user, _ = get_env_string("USERNAME", ST.alloc)
	} else {
		ST.user, _ = get_env_string("USER", ST.alloc)
	}

	// default log location
	if CFG.save_file {
		f, err := os.get_executable_path(context.allocator)
		defer delete(f)

		dir, name := filepath.split(f)
		if err != nil do name = "Unknown"
		if i := strings.last_index_byte(name, '.'); i >= 0 {
			name = name[:i]
		}

		ld, _ := filepath.join({dir, ".logs"})
		defer delete(ld)
		if CFG.log_dir != "" do delete(CFG.log_dir, ST.alloc)
		CFG.log_dir = strings.clone(ld, ST.alloc)

		// `name` slices into f, which the defer above frees - clone it
		if ST.prog_name != "" do delete(ST.prog_name, ST.alloc)
		ST.prog_name = strings.clone(name, ST.alloc)

		ts_buf: [64]u8
		fn := fmt.tprintf("%s__%s.jsonl", ST.prog_name, timestamp(ts_buf[:], true))
		lp, _ := filepath.join({CFG.log_dir, fn})
		defer delete(lp)
		if ST.log_path != "" do delete(ST.log_path, ST.alloc)
		ST.log_path = strings.clone(lp, ST.alloc)
		os.make_directory_all(CFG.log_dir)
	} else {
		fmt.println("Unable to set log directory, please manually set path with init()")
	}

	// color use
	no_color := env_is_set("NO_COLOR")
	force_color := env_is_set("FORCE_COLOR")
	force_no_color := env_is_set("FORCE_NO_COLOR")
	CFG.use_color = (!force_no_color && !no_color) || force_color

	if os.exists("muninn.verbose.lock") {
		set_log_level(.TRACE)
		CFG.verbose = true
	} else {
		if v, ok := get_env_string("LOG_LEVEL"); ok && len(v) > 0 {
			set_level(v)
		}
	}

	// trace if in debug
	when ODIN_DEBUG {
		ok := trace.init(&ST.trace_ctx)
		if CFG.verbose do fmt.printfln("> trace init set? %v", ok)
	}
}


/***************************************************************************************************
 * [ Auto Exit ]
***************************************************************************************************/
@(fini)
@(private)
cleanup :: proc() {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.lock(&ST.log_mutex)
	group_flush_locked() // dump any pending thread boxes first
	flush_locked()
	if ST.editing_file != nil {
		os.close(ST.editing_file)
		ST.editing_file = nil
	}
	strings.builder_destroy(&ST.file_buf)
	group_drop_locked()
	delete(ST.group_win)
	sync.unlock(&ST.log_mutex)

	when ODIN_DEBUG {
		trace.destroy(&ST.trace_ctx)
	}

	// log rotation
	if !CFG.save_file || CFG.log_dir == "" do return

	prefix := fmt.tprintf("%s__", ST.prog_name)
	safe := make([dynamic]string, 0, CFG.rotate_days + 1, context.temp_allocator)
	for i in 0 ..< CFG.rotate_days {
		ts_buf: [64]u8
		append(&safe, fmt.tprintf("%s%s.jsonl", prefix, timestamp(ts_buf[:], true, i)))
	}

	files, err := os.read_directory_by_path(CFG.log_dir, -1, context.allocator)
	if err != nil do return
	// each File_Info owns its name/fullpath strings - delete(files) alone leaks them
	defer os.file_info_slice_delete(files, context.allocator)

	for f in files {
		if f.type == .Directory do continue
		if f.fullpath == ST.log_path do continue
		if !strings.has_prefix(f.name, prefix) do continue
		if !strings.has_suffix(f.name, ".jsonl") do continue
		if !slice.contains(safe[:], f.name) do os.remove(f.fullpath)
	}
}

// caller MUST hold ST.log_mutex
@(private)
flush_locked :: proc() {
	if ST.editing_file == nil do return
	if strings.builder_len(ST.file_buf) == 0 do return
	os.write_string(ST.editing_file, strings.to_string(ST.file_buf))
	strings.builder_reset(&ST.file_buf)
}

/***************************************************************************************************
 * [ User Exit with code ]
***************************************************************************************************/

// simple exit routine - just pass the error code
exit :: proc(code: int = 0) {
  color := GREEN
  if code > 0 {
    color = RED
  }

  sep(color=color, nl_pre=true, char="─")
  info("Exiting program with code: %d", code)
  flush()
  os.exit(code)
}


/***************************************************************************************************
 * [ Manual Init ]
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
  - show_func: show the function name as well. Needs show_location.
  - show_runtime: prepend `[ HH:MM:SS ]` elapsed since process start.
  - show_timestamp: prepend `[ YYYY-MM-DD HH:MM:SS ]` local wall clock.
  - show_pid: append the process id.
  - show_tid: append the thread id. Redundant with group_by_thread, since the
      box label already carries it.
  - truncate_long_lines: what to do with a row wider than the terminal.
      true (default) cuts it at the edge and marks it with an ellipsis, so one
      log line is always one row. false wraps it onto as many rows as it needs,
      keeping the whole message at the cost of a taller box. Only affects
      grouped output - ungrouped lines are handed to the terminal as-is.

  Thread / job grouping (ignored when emit_json is true)
  - group_by_thread: collect each thread's lines into its own window and print
      them inside a labeled box instead of interleaving them. Every row and
      both rails are padded to the widest line in the window, so the box is
      always square. The window is settled when another thread logs, on
      mn.flush(), on fatal, at exit, or on mn.reset_ctx() / ctx_reset=true.
  - group_max_lines: how many rows one window holds.
  - force_box_term_width: pin the box to the full terminal width instead of
      shrinking it to fit its contents. false (default) sizes each box to its
      own longest row, so a box of short lines stays small and the frame width
      moves around as you read. true makes every box span the terminal, which
      keeps the rails in one place down the whole log at the cost of a lot of
      trailing whitespace on short rows. Narrow terminals still widen past this
      if the thread_id label needs the room.
  - grouped_logs_stream: picks how a full window rotates.

      true (default) - STREAM rotation. Every message reprints the whole
        window as a finished box, so output appears the instant it is logged
        and an error can never sit unflushed. Once the window is full the
        oldest row is shed as each new one arrives, so each box is the most
        recent N lines. Costs you one box per message - loud, but nothing is
        ever late.

      false - BLOCK rotation. Lines accumulate quietly and one box is emitted
        each time the window fills, then it starts over. Roughly N times less
        output, but a line can sit in the window until the block completes or
        something forces a flush. Good for batch jobs and piping to a file,
        bad for watching a live crash.

  ```odin
    import mn "./.."

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
	show_func: Maybe(bool) = nil,
	short_location: Maybe(bool) = nil,
	show_runtime: Maybe(bool) = nil,
	show_timestamp: Maybe(bool) = nil,
	show_pid: Maybe(bool) = nil,
	show_tid: Maybe(bool) = nil,
	truncate_long_lines: Maybe(bool) = nil,
	//
	group_max_lines: Maybe(int) = nil,
	group_by_thread: Maybe(bool) = nil,
	grouped_logs_stream: Maybe(bool) = nil,
	force_box_term_width: Maybe(bool) = nil,
	//
	log_dir: Maybe(string) = nil,
	save_file: Maybe(bool) = nil,
) {
	// ---------------------------------------------------------------- verbosity and rotation
	if v, ok := level.?; ok do set_log_level(v)
	if v, ok := rotate_days.?; ok do CFG.rotate_days = max(0, v)

	// ----------------------------------------------------------------  pretty formatting
	if v, ok := show_stack_trace.?; ok do CFG.show_stack = v
	if v, ok := emit_json.?; ok do CFG.emit_json = v
	if v, ok := use_color.?; ok do CFG.use_color = v
	if v, ok := show_location.?; ok do CFG.show_location = v
	if v, ok := show_func.?; ok do CFG.show_func = v
	if v, ok := short_location.?; ok do CFG.short_location = v
	if v, ok := show_runtime.?; ok do CFG.show_runtime = v
	if v, ok := show_timestamp.?; ok do CFG.show_timestamp = v
	if v, ok := show_pid.?; ok do CFG.show_pid = v
	if v, ok := show_tid.?; ok do CFG.show_tid = v
	if v, ok := truncate_long_lines.?; ok do CFG.truncate_long_lines = v

	// ----------------------------------------------------------------  grouping
	if v, ok := group_max_lines.?; ok do CFG.group_max_lines = max(1, v)
	if v, ok := force_box_term_width.?; ok do CFG.force_box_term_width = v
	if v, ok := grouped_logs_stream.?; ok {
		// settle whatever is pending under the old mode before switching
		if v != CFG.grouped_logs_stream && CFG.group_by_thread do flush()
		CFG.grouped_logs_stream = v
	}
	if v, ok := group_by_thread.?; ok {
		if !v && CFG.group_by_thread do flush()
		CFG.group_by_thread = v
	}

	// ----------------------------------------------------------------  file sink
	want_dir, dir_given := log_dir.?
	save_given := false
	if v, ok := save_file.?; ok {
		CFG.save_file = v
		save_given = true
	}

	if dir_given || save_given {
		sync.lock(&ST.log_mutex)
		defer sync.unlock(&ST.log_mutex)

		if dir_given && want_dir != CFG.log_dir {
			rebuild_log_path_locked(want_dir)
		} else if CFG.save_file && ST.log_path == "" && CFG.log_dir != "" {
			rebuild_log_path_locked(CFG.log_dir)
		}
		reopen_file_locked()
	}
}

// caller must hold ST.log_mutex
// swaps the log directory and derives a fresh PROG__DATE.jsonl path from it
@(private)
rebuild_log_path_locked :: proc(fpath: string) {
	dir, _ := filepath.split(fpath)
	os.make_directory_all(dir)

	// filepath.split hands back SLICES INTO fpath, it does not allocate. storing
	// `dir` raw would leave CFG.log_dir pointing into the caller's string - and
	// when that is a literal, the delete on the next call frees rodata and the
	// process dies. clone it.
	new_dir := strings.clone(dir, ST.alloc)
	new_path := strings.clone(fpath, ST.alloc)

	// clone BEFORE freeing: fpath may alias the very strings we are about to drop
	if CFG.log_dir != "" do delete(CFG.log_dir, ST.alloc)
	if ST.log_path != "" do delete(ST.log_path, ST.alloc)

	CFG.log_dir = new_dir
	ST.log_path = new_path
}

// caller must hold ST.log_mutex
// idempotent: closes whatever's open, reopens only if we should be saving
@(private)
reopen_file_locked :: proc() {
	flush_locked()
	if ST.editing_file != nil {
		os.close(ST.editing_file)
		ST.editing_file = nil
	}
	if !CFG.save_file || ST.log_path == "" do return

	ef, err := os.open(ST.log_path, {.Write, .Create, .Append})
	if err != nil {
		fmt.println(err)
		return
	}
	ST.editing_file = ef
	if cap(ST.file_buf.buf) == 0 {
		strings.builder_init(&ST.file_buf, 0, FLUSH_AT + LINE_CAP, ST.alloc)
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
	flush()
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
	char: string = "─",
	color: string = BLUE,
	nl_pre: bool = false,
	nl_post: bool = false,
) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// temp, not a fixed stack array: a wide terminal or a multi-char separator
	// blows past any fixed size and a non-growable builder drops the overflow
	b := strings.builder_make(context.temp_allocator)

	bar := repeat(char)
	defer delete(bar)

	if nl_pre do strings.write_byte(&b, '\n')
	if CFG.use_color do strings.write_string(&b, color)
	strings.write_string(&b, bar)
	if CFG.use_color do strings.write_string(&b, RESET)
	strings.write_byte(&b, '\n')
	if nl_post do strings.write_byte(&b, '\n')

	// same lock as central_log so separators can't land mid-line
	sync.lock(&ST.log_mutex)
	console_write(strings.to_string(b))
	sync.unlock(&ST.log_mutex)
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
  import mn "./.."

  mr.title(msg="Some Title", char="-", color=mr.RED)
  mr.title(msg="Some Title", char="-", color="\x1b[38;5;77m")
  ```
*/
title :: proc(msg: string, char: string = "═", color: string = BLUE) {
	sep(char, color, nl_pre = true)
	m := fmt.tprintf("%s* [ %s ]%s", color, msg, RESET) if CFG.use_color else msg
	fmt.println(m)
	sep(char, color)
}


/***************************************************************************************************
 * [ context.logger bridge ]
 Routes anything that logs through `context.logger` (core:log, and any third-party lib that uses it)
 into muninn's pipeline: same formatting, same jsonl sink, same thread grouping, same level gate.

 Auto-attached in @(init). Nothing to call.
***************************************************************************************************/

/*
logger returns the muninn logger as a plain runtime.Logger - the exact type of
`context.logger` (core:log's `log.Logger` is an alias of it). Attach it manually
if you ever blow away the context yourself, or on a worker thread that started
from a fresh context:

  ```odin
  context.logger = mn.logger()
  ```

Args:
  - lowest (optional): core:log formats its args BEFORE handing the string over,
      so this is the only place that cost can be skipped. Defaults to .Debug,
      which lets everything through and leaves muninn's own atomic level as the
      single source of truth. Pass a level here only if the format cost of
      dropped messages actually shows up in a profile.
*/
logger :: proc "contextless" (lowest: runtime.Logger_Level = .Debug) -> runtime.Logger {
	return runtime.Logger {
		procedure = context_logger_proc,
		data = nil,
		lowest_level = lowest,
		options = {},
	}
}

/*
hooked reports whether a logger is muninn's. pass your own context.logger in -
muninn's procs read this file's global context, not the caller's, so it can't
go get it for you:

```odin
  if !mn.hooked(context.logger) do context.logger = mn.logger()
```
*/
hooked :: proc "contextless" (l: runtime.Logger) -> bool {
	return l.procedure == context_logger_proc
}

// only lands if the calling code is also `#+feature global-context`
@(private)
@(init)
_hook_context_logger :: proc() {
	context.logger = logger()
}

// reentrancy guard
@(private, thread_local)
IN_BRIDGE: bool

@(private)
context_logger_proc :: proc(
	data: rawptr, // unused - the logger is stateless
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options, // unused - muninn does its own formatting
	loc := #caller_location,
) {
	if IN_BRIDGE do return

	lvl := level_from_runtime(level)
	if lvl < log_level() do return

	IN_BRIDGE = true
	defer IN_BRIDGE = false

	tag, clr: string
	switch lvl {
	case .TRACE:
		tag, clr = "[ TRACE ]", GRAY
	case .DEBUG:
		tag, clr = "[ DEBUG ]", BLUE
	case .INFO:
		tag, clr = "[ INFO  ]", GREEN
	case .WARN:
		tag, clr = "[ WARN  ]", YELLOW
	case .ERROR:
		tag, clr = "[ ERROR ]", RED
	case .FATAL:
		tag, clr = "[ FATAL ]", MAGENTA
	}

	_log(lvl, tag, clr, text, nil, false, lvl >= .ERROR, loc)
	if lvl >= .FATAL do flush()
}

@(private)
// map log levels
level_from_runtime :: proc "contextless" (l: runtime.Logger_Level) -> Levels {
	switch l {
	case .Debug:
		return .DEBUG
	case .Info:
		return .INFO
	case .Warning:
		return .WARN
	case .Error:
		return .ERROR
	case .Fatal:
		return .FATAL
	}
	return .INFO
}


/***************************************************************************************************
 * [ Sanitation ]
***************************************************************************************************/

// flush buffered file output. call before a hard exit / os.exit().
// @(fini) already does this on a normal return from main.
flush :: proc() {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.lock(&ST.log_mutex)
	group_flush_locked()
	flush_locked()
	sync.unlock(&ST.log_mutex)
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
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.once_do(&ST.init_once, validate_requirements)

	// redeclare for thread safety
	save := CFG.save_file
	emit := CFG.emit_json
	color := CFG.use_color
	tid := thread_id()

	ts_buf: [64]u8
	ts: string
	if CFG.show_timestamp do ts = timestamp(ts_buf[:])

	rt_buf: [time.MIN_HMS_LEN]u8
	rt: string
	if CFG.show_runtime do rt = time.to_string_hms(time.since(ST.started), rt_buf[:])

	fpath, fname, func: string
	line, col: int
	if CFG.show_location {
		fpath = loc.file_path

    if ST.rel_loc == "" {
      caller, _ := strings.split_multi(fpath, {"/", "\\"})
      defer delete(caller)

      slice.reverse(caller)
      for p, _ in caller {
        if !strings.contains(ST.self_loc, p) {
          continue
        }
        ST.rel_loc = p
        break
      }
    }

    post := strings.split(loc.file_path, ST.rel_loc)
    fname, _ = filepath.join({".", post[len(post) - 1]})
		line = int(loc.line)
		col = int(loc.column)
		func = ""
		if CFG.show_func {
			func = loc.procedure
		}
	}

	fmt_st: string
	vec_st: []string
	if s_trace {
		sync.lock(&ST.trace_mutex)
		fmt_st, vec_st = get_trace()
		sync.unlock(&ST.trace_mutex)
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
		jw_str(&w, "user", ST.user)
		jw_str(&w, "file", fpath)
		jw_int(&w, "process_id", ST.proc_id)
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

		if CFG.show_location {
			if color do strings.write_string(&lb, GRAY)
			strings.write_string(&lb, " > ")
			strings.write_string(&lb, fname if CFG.short_location else fpath)
			strings.write_byte(&lb, ':')
			strings.write_int(&lb, line)
			strings.write_string(&lb, " ( ")
			strings.write_string(&lb, func)
			strings.write_string(&lb, " )")
			if color do strings.write_string(&lb, RESET)
		}

		if CFG.show_pid || CFG.show_tid {
			if color do strings.write_string(&lb, GRAY)
			strings.write_string(&lb, " :: ( ")
			if CFG.show_pid {
				strings.write_string(&lb, "process_id = ")
				strings.write_int(&lb, ST.proc_id)
			}
			if CFG.show_pid && CFG.show_tid do strings.write_string(&lb, " | ")
			if CFG.show_tid {
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
	sync.lock(&ST.log_mutex)
	if save && ST.editing_file != nil {
		strings.write_string(&ST.file_buf, json_line)
		strings.write_byte(&ST.file_buf, '\n')
		if s_trace || strings.builder_len(ST.file_buf) >= FLUSH_AT {
			flush_locked()
		}
	}

	if emit {
		console_write(json_line)
		console_write("\n")
	} else if CFG.group_by_thread {
		group_push_locked(tid, pretty)
	} else {
		console_write(pretty)
	}
	sync.unlock(&ST.log_mutex)
}


/***************************************************************************************************
 * [ Thread grouping ]

 Each thread collects its rows into a window of CFG.group_max_lines. How that window rotates
 once it is full depends on CFG.grouped_logs_stream:

   stream (true)  every message sheds the oldest row if needed and reprints the WHOLE window as
                  a finished box, so output is never deferred and each box is the last N rows.
   block  (false) rows pile up silently and one box is emitted when the window fills, then the
                  window starts over. Far less output, but rows wait for the block to complete.

 Either way the box is drawn in a single pass, so every row and both rails share the same width.
***************************************************************************************************/

// caller must hold ST.log_mutex
@(private)
group_push_locked :: proc(tid: int, line: string) {
	// a different thread took over - settle the old window before starting this one
	if ST.group_tid != tid {
		group_close_locked()
		ST.group_tid = tid
	}

	// stack traces arrive with embedded newlines - one row each or the box tears
	segments := strings.split(strings.trim_right(line, "\n"), "\n")
	defer delete(segments)

	if CFG.truncate_long_lines {
		for seg in segments do append(&ST.group_win, strings.clone(seg, ST.alloc))
	} else {
		// wrap now, so one wrapped row is one window row and max_lines still means rows
		tw := get_term_width()
		if tw <= 0 do tw = DEFAULT_WIDTH
		for seg in segments {
			for part in ansi_wrap(seg, max(1, tw - 3), ST.alloc) {
				append(&ST.group_win, part)
			}
		}
	}

	if CFG.grouped_logs_stream {
		// shed the oldest rows until we are back inside the window, then redraw it all
		for len(ST.group_win) > CFG.group_max_lines {
			delete(ST.group_win[0], ST.alloc)
			ordered_remove(&ST.group_win, 0)
		}
		group_box_locked(tid, ST.group_win[:])
	} else if len(ST.group_win) >= CFG.group_max_lines {
		// window is full - emit it as one block and start the next
		group_box_locked(tid, ST.group_win[:])
		group_drop_locked()
	}
}

// caller must hold ST.log_mutex
// frees the window without printing. keeps ST.group_tid so the same thread keeps its box
@(private)
group_drop_locked :: proc() {
	for s in ST.group_win do delete(s, ST.alloc)
	clear(&ST.group_win)
}

// caller must hold ST.log_mutex
// settles the window. in stream mode the box on screen is already finished so this only frees,
// in block mode the partial block still has to be emitted or those rows are lost
@(private)
group_close_locked :: proc() {
	if ST.group_tid == -1 do return
	if !CFG.grouped_logs_stream && len(ST.group_win) > 0 {
		group_box_locked(ST.group_tid, ST.group_win[:])
	}
	group_drop_locked()
	ST.group_tid = -1
}

// caller must hold ST.log_mutex
@(private)
group_close_one_locked :: proc(tid: int) {
	if ST.group_tid == tid do group_close_locked()
}

// caller must hold ST.log_mutex
@(private)
group_flush_locked :: proc() {
	group_close_locked()
}

// caller must hold ST.log_mutex
// draws the window as one finished box, sized to the widest row in it
@(private)
group_box_locked :: proc(tid: int, lines: []string) {
	if len(lines) == 0 do return

	label := fmt.tprintf("[ thread_id = %d ]", tid)

	tw := get_term_width()
	if tw <= 0 do tw = DEFAULT_WIDTH

	widths := make([dynamic]int, 0, len(lines), context.temp_allocator)
	max_len := 0
	for s in lines {
		w := ansi_width(s)
		append(&widths, w)
		if w > max_len do max_len = w
	}

	// pinned to the terminal, or shrunk to fit the widest row
	inner := tw - 2 if CFG.force_box_term_width else min(max_len + 2, tw - 2)
	// never let the label overrun the top rail, however narrow the terminal is
	inner = max(inner, len(label) + 2)

	bc :: proc(s: string) -> string {
		return fmt.tprintf("%s%s%s", BLUE, s, RESET) if CFG.use_color else s
	}

	sb := strings.builder_make(context.temp_allocator)

	// top: label cut into the frame
	fill := strings.repeat("═", max(0, inner - 1 - len(label)), context.temp_allocator)
	fmt.sbprintf(&sb, "%s\n", bc(fmt.tprintf("╔═%s%s╗", label, fill)))

	// body
	for s, i in lines {
		body, vis := s, widths[i]
		if vis > inner - 1 {
			// wrapped rows already fit; this only fires for truncate mode
			body = ansi_truncate(s, inner - 1)
			vis = inner - 1
		}
		gap := strings.repeat(" ", max(0, inner - 1 - vis), context.temp_allocator)
		fmt.sbprintf(&sb, "%s %s%s%s\n", bc("║"), body, gap, bc("║"))
	}

	// bottom
	bfill := strings.repeat("═", inner, context.temp_allocator)
	fmt.sbprintf(&sb, "%s\n", bc(fmt.tprintf("╚%s╝", bfill)))

	console_write(strings.to_string(sb))
}

// drops this thread's window, if it owns one
group_reset :: proc() {
	if !CFG.group_by_thread do return
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	tid := thread_id()
	sync.lock(&ST.log_mutex)
	group_close_one_locked(tid)
	sync.unlock(&ST.log_mutex)
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

// caller must hold ST.trace_mutex
@(private)
get_trace :: proc() -> (string, []string) {

	when !ODIN_DEBUG do return "", nil
	if !CFG.show_stack do return "", nil

	vec := make([dynamic]string, 0, 16, context.temp_allocator)
	buf: [64]trace.Frame
	frames := trace.frames(&ST.trace_ctx, 3, buf[:])

	Row :: struct {
		arm:   string,
		rest:  string,
		depth: int,
		clr:   string,
	}
	rows := make([dynamic]Row, 0, 16, context.temp_allocator)

	is_src := true
	for f in frames {
		fl := trace.resolve(&ST.trace_ctx, f, context.temp_allocator)
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
		trimmed := make([dynamic]string, 0, TRACE_MAX + 1, context.temp_allocator)
		append(&trimmed, ..vec[:TRACE_HEAD])
		append(&trimmed, TRUNC_MARK)
		append(&trimmed, ..vec[len(vec) - TRACE_TAIL:])
		vec = trimmed
	}

	if len(rows) == 0 do return "", vec[:]
	if len(rows) > 1 do rows[len(rows) - 1].arm = "LAST > "

	shown := rows
	if len(rows) > TRACE_MAX {
		shown = make([dynamic]Row, 0, TRACE_MAX + 1, context.temp_allocator)
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
	texts := make([dynamic]string, 0, len(shown), context.temp_allocator)
	max_len := 0
	for r in shown {
		pad := strings.repeat(" ", r.depth * 2, context.temp_allocator)
		t := fmt.tprintf("%s%s%s", pad, r.arm, r.rest)
		append(&texts, t)
		if len(t) > max_len do max_len = len(t)
	}

	inner := max_len + 2
	sb := strings.builder_make(context.temp_allocator)

	c :: proc(s: string) -> string {
		return fmt.tprintf("%s%s%s", RED, s, RESET) if CFG.use_color else s
	}

	// top
	fmt.sbprintf(
		&sb,
		"\n%s",
		c(fmt.tprintf("╔%s╗", strings.repeat("═", inner, context.temp_allocator))),
	)

	// body
	for r, i in shown {
		plain := texts[i]
		body := plain
		if CFG.use_color {
			pad := strings.repeat(" ", r.depth * 2, context.temp_allocator)
			if r.arm == "" {
				body = fmt.tprintf("%s%s%s%s", pad, r.clr, r.rest, RESET)
			} else {
				body = fmt.tprintf("%s%s%s%s%s", pad, r.clr, r.arm, RESET, r.rest)
			}
		}
		gap := strings.repeat(" ", max(0, inner - 1 - len(plain)), context.temp_allocator)
		fmt.sbprintf(&sb, "\n%s %s%s%s", c("║"), body, gap, c("║"))
	}

	// bottom
	fmt.sbprintf(
		&sb,
		"\n%s",
		c(fmt.tprintf("╚%s╝", strings.repeat("═", inner, context.temp_allocator))),
	)

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

// splits s into chunks of at most max_vis visible columns, carrying the active
// ANSI state onto each chunk so colors survive the break. escape sequences cost
// no width, and utf8 continuation bytes never start a new chunk.
@(private)
ansi_wrap :: proc(s: string, max_vis: int, allocator := context.allocator) -> []string {
	// container and scratch are temp - only the finished rows use `allocator`,
	// since those are what the caller keeps
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	if max_vis < 1 {
		append(&out, strings.clone(s, allocator))
		return out[:]
	}

	b := strings.builder_make(context.temp_allocator)
	sgr := strings.builder_make(context.temp_allocator) // active escapes so far
	n, i := 0, 0

	flush_chunk :: proc(
		b: ^strings.Builder,
		out: ^[dynamic]string,
		sgr: string,
		allocator: runtime.Allocator,
	) {
		if CFG.use_color do strings.write_string(b, RESET)
		append(out, strings.clone(strings.to_string(b^), allocator))
		strings.builder_reset(b)
		strings.write_string(b, sgr) // re-open the colors on the next row
	}

	for i < len(s) {
		if s[i] == 0x1b {
			start := i
			i += 1
			if i < len(s) && s[i] == '[' {
				i += 1
				for i < len(s) && !(s[i] >= 0x40 && s[i] <= 0x7e) do i += 1
				if i < len(s) do i += 1
			}
			esc := s[start:i]
			strings.write_string(&b, esc)
			if esc == RESET {
				strings.builder_reset(&sgr)
			} else {
				strings.write_string(&sgr, esc)
			}
			continue
		}
		if s[i] & 0xc0 != 0x80 {
			if n >= max_vis {
				flush_chunk(&b, &out, strings.to_string(sgr), allocator)
				n = 0
			}
			n += 1
		}
		strings.write_byte(&b, s[i])
		i += 1
	}

	if strings.builder_len(b) > 0 || len(out) == 0 {
		if CFG.use_color do strings.write_string(&b, RESET)
		append(&out, strings.clone(strings.to_string(b), allocator))
	}
	return out[:]
}

// clip to max_vis visible runes, passing escapes through untouched
@(private)
ansi_truncate :: proc(s: string, max_vis: int) -> string {
	b := strings.builder_make(context.temp_allocator)
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
	if CFG.use_color do strings.write_string(&b, RESET)
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

	sync.lock(&ST.time_mutex)
	defer sync.unlock(&ST.time_mutex)

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
	// deliberately NOT context.allocator: this outlives every scope in the
	// program and is still used at @(fini), long after any arena is gone
	ST.group_win = make([dynamic]string, 0, 64, ST.alloc)

	if CFG.verbose do fmt.printfln("> save file? %t", CFG.save_file)
	if CFG.save_file {
		if CFG.verbose do fmt.printfln("> log dir? %s", CFG.log_dir)
		if CFG.log_dir == "" {
			panic("Log directory not set, please manually set with init()")
		}

		if CFG.verbose do fmt.printfln("> log path? %s", ST.log_path)
		if ST.log_path == "" {
			panic("Log path did not get set, please manually set with init()")
		}

		if ST.editing_file == nil {
			ef, err := os.open(ST.log_path, {.Write, .Create, .Append})
			if err != nil {
				fmt.println(err)
				panic(
					fmt.tprintf(
						"Unable to create logs in %s, please manually set with init()",
						CFG.log_dir,
					),
				)
			}
			ST.editing_file = ef
			strings.builder_init(&ST.file_buf, 0, FLUSH_AT + LINE_CAP, ST.alloc)
		}
		if CFG.verbose do fmt.printfln("> editing file is nil? %t", ST.editing_file == nil)
	}

	if CFG.verbose do fmt.printfln("> is valid? %t", true)
	if CFG.verbose do sep(color = GRAY)
}

@(private)
repeat :: proc(char: string, i: int = 0) -> string {
	i := i if i > 0 else get_term_width()
	return strings.repeat(char, i)
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

	foreign import libc_sys "system:c"

	@(private)
	winsize :: struct {
		ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
	}
	@(private)
	TIOCGWINSZ :: c.ulong(0x5413) when ODIN_OS == .Linux else c.ulong(0x40087468)

	@(private)
	foreign libc_sys {
		ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
	}
}

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
