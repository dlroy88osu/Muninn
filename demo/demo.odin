// muninn/example/main.odin
//
//   odin run . -debug      <- -debug so the stack trace boxes render
//
// One pass over every knob init() exposes, every public proc, and the
// context.logger bridge. Each section prints a title, says what you should be
// looking at, then a plain separator - so if a section's output does not match
// its blurb, that flag is broken.
package main

import mn "./.."
// import "./tee"  // THESE OF FOR ME TO GIVE YOU THOSE JUICY PICS!
import "core:fmt"
import "core:log"
import "core:strings"
import "core:thread"

STEP := 0

// title -> what to expect -> plain default separator
section :: proc(name, expect: string) {
	STEP += 1
	mn.title(fmt.tprintf("%d. %s", STEP, name))
	fmt.printfln("\x1b[38;5;244m  expect: %s\x1b[0m", expect)
	mn.sep()
}

// every section starts from a known state so nothing leaks across sections
baseline :: proc() {
	mn.init(
		level = .TRACE,
		save_file = false,
		emit_json = false,
		use_color = true,
		show_stack_trace = true,
		show_location = true,
		show_func = false,
		short_location = true,
		show_runtime = false,
		show_timestamp = false,
		show_pid = false,
		show_tid = false,
		truncate_long_lines = true,
		group_by_thread = false,
		group_max_lines = 8,
		grouped_logs_stream = true,
		force_box_term_width = false,
	)
}

main :: proc() {
	// tee.start() // THESE OF FOR ME TO GIVE YOU THOSE JUICY PICS!
	// defer tee.stop() // THESE OF FOR ME TO GIVE YOU THOSE JUICY PICS!

	// the bridge has to be attached at YOUR top level - see section 15
	context.logger = mn.logger()
	baseline()

	levels()
	deep_nested_error()
	level_gate()
	location_flags()
	time_flags()
	id_flags()
	color_flag()
	stack_flag()
	json_flag()
	file_sink()
	file_save_location()
	grouping_basics()
	rotation_modes()
	long_line_modes()
	box_width_modes()
	context_reset()
	bridge()
	separators()

	mn.title("done", char = "=", color = mn.GREEN)
	mn.flush()
}

/***************************************************************************************************
 * levels
***************************************************************************************************/

levels :: proc() {
	section(
		"level :: the six severities",
		"6 colored lines TRACE->FATAL. `warning` is just an alias of `warn`",
	)
	baseline()

	mn.trace("trace - gray, the noisiest")
	mn.debug("debug - blue")
	mn.info("info - green")
	mn.warn("warn - yellow")
	mn.warning("warning - same proc as warn, nothing new")
	mn.error("error - red, and >= ERROR drags a stack box along")
	// mn.fatal(...) is deliberately NOT called: it logs, flushes, then panics.
}

level_gate :: proc() {
	section(
		"level + is_enabled :: the gate",
		"2 kept lines, 2 dropped. is_enabled reports false for DEBUG, then true once reopened",
	)
	baseline()

	mn.init(level = .WARN)
	mn.debug("DROPPED - below the gate")
	mn.info("DROPPED - below the gate")
	mn.warn("KEPT - at the gate")
	mn.error("KEPT - above the gate")

	// gate a hot path without paying to build the args
	fmt.printfln("  is_enabled(.DEBUG) = %t", mn.is_enabled(.DEBUG))
	if mn.is_enabled(.DEBUG) do mn.debug("you should NOT see this")

	mn.init(level = .TRACE)
	fmt.printfln("  after init(level = .TRACE), is_enabled(.DEBUG) = %t", mn.is_enabled(.DEBUG))

	// two more ways in, neither needs a call:
	//   set LOG_LEVEL=debug        - env var, read once at startup
	//   muninn.verbose.lock file   - if present, forces TRACE + logger diagnostics
	fmt.printfln("  also settable at startup by LOG_LEVEL, or a muninn.verbose.lock file")
}

/***************************************************************************************************
 * pretty formatting
***************************************************************************************************/

location_flags :: proc() {
	section(
		"show_location + short_location :: where did this come from",
		"3 lines: bare, then `main.odin:NN ( proc )`, then the full absolute path",
	)
	baseline()

	mn.init(show_location = false)
	mn.info("show_location = false - message only")

	mn.init(show_location = true, show_func = true)
	mn.info("show_func = true - should see function name == location_flags")

	mn.init(show_location = true, short_location = true, show_func = false)
	mn.info("short_location = true - basename only")

	mn.init(short_location = false)
	mn.info("short_location = false - whole path, gets long fast")
}

time_flags :: proc() {
	section(
		"show_runtime + show_timestamp :: two clocks",
		"4 lines: neither, elapsed only, wall clock only, then both prefixed",
	)
	baseline()

	mn.init(show_runtime = false, show_timestamp = false)
	mn.info("no clocks at all")

	mn.init(show_runtime = true)
	mn.info("show_runtime - [ HH:MM:SS ] since process start")

	mn.init(show_runtime = false, show_timestamp = true)
	mn.info("show_timestamp - [ YYYY-MM-DD HH:MM:SS ] local wall clock")

	mn.init(show_runtime = true)
	mn.info("both, timestamp first")
}

id_flags :: proc() {
	section(
		"show_pid + show_tid :: who logged it",
		"4 lines: neither, pid, tid, then both appended",
	)
	baseline()

	mn.init(show_pid = false, show_tid = false)
	mn.info("no ids")

	mn.init(show_pid = true)
	mn.info("show_pid - process id")

	mn.init(show_pid = false, show_tid = true)
	mn.info("show_tid - thread id (redundant once group_by_thread is on)")

	mn.init(show_pid = true)
	mn.info("both")
}

color_flag :: proc() {
	section(
		"use_color :: ANSI on or off",
		"2 colored lines, then 2 plain ones - same text, zero escape codes",
	)
	baseline()

	mn.info("use_color = true - green info")
	mn.warn("use_color = true - yellow warn")

	mn.init(use_color = false)
	mn.info("use_color = false - plain info, safe for pipes and CI logs")
	mn.warn("use_color = false - plain warn")
	mn.init(use_color = true)
}

stack_flag :: proc() {
	section(
		"show_stack_trace :: the box under an error",
		"1 error WITH a stack box, then 1 error WITHOUT one",
	)
	baseline()

	mn.init(show_stack_trace = true)
	mn.error("show_stack_trace = true - stack box follows")

	mn.init(show_stack_trace = false)
	mn.error("show_stack_trace = false - error line only")
}

/***************************************************************************************************
 * output routing
***************************************************************************************************/

json_flag :: proc() {
	section(
		"emit_json :: structured output",
		"2 raw jsonl lines - no color, no box, no grouping. for log shippers",
	)
	baseline()

	mn.init(emit_json = true, show_stack_trace = false)
	mn.info("this is a json line")
	mn.warn("so is this one")
	mn.init(emit_json = false)
}

file_sink :: proc() {
	section(
		"save_file + log_dir + rotate_days :: the disk sink",
		"3 console lines; the same 3 land in .logs/demo.jsonl as json",
	)
	baseline()

	// log_dir takes the full file path - the directory is created for you
	mn.init(save_file = true, log_dir = ".logs/demo.jsonl", rotate_days = 3)
	mn.info("written to console AND to disk")
	mn.warn("rotate_days = 3 - older demo__DATE.jsonl files pruned at exit")
	mn.error("errors carry their stack array into the json too")

	mn.flush() // force the buffer out now instead of at exit
	mn.init(save_file = false)
	fmt.printfln("  wrote .logs/demo.jsonl - `type .logs\\demo.jsonl` to read it")
}


file_save_location :: proc() {
	section(
		"log_dir again :: moving the sink mid-run",
		"2 console lines landing in a SECOND file - the first one keeps what it already had",
	)
	baseline()

	// switching is safe any number of times; nested dirs are created for you
	mn.init(save_file = true, log_dir = ".logs/new_loc/demo.jsonl", rotate_days = 3)
	mn.info("this one goes to the new location, not the old one")
	mn.warn("the previous file was flushed and closed on the switch")

	mn.flush()
	mn.init(save_file = false)
	fmt.printfln("  .logs/demo.jsonl = 3 lines, .logs/new_loc/demo.jsonl = 2 lines")
}

/***************************************************************************************************
 * thread / job grouping
***************************************************************************************************/

grouping_basics :: proc() {
	section(
		"group_by_thread + group_max_lines :: boxed output",
		"ungrouped lines first, then the same lines boxed and labeled with the thread id",
	)
	baseline()

	mn.info("group_by_thread = false - lines go straight out")
	mn.info("second ungrouped line")

	mn.init(group_by_thread = true, group_max_lines = 4, show_location = false)
	mn.info("grouped - the box widens to its longest row")
	mn.info("every row pads out to match, so the rails stay square")
	mn.reset_ctx()
}

rotation_modes :: proc() {
	section(
		"grouped_logs_stream :: how a full window rotates",
		"STREAM: a box per message, sliding 1-6 then 2-7 ... BLOCK: 1-6, 7-12, then the 13-15 tail",
	)
	baseline()
	mn.init(group_by_thread = true, group_max_lines = 6, show_location = false)

	mn.init(grouped_logs_stream = true)
	fmt.printfln("\x1b[1m  -- STREAM (default): every message reprints the window --\x1b[0m")
	for i in 1 ..= 15 do mn.info("count = %d", i)
	mn.reset_ctx()

	mn.init(grouped_logs_stream = false)
	fmt.printfln("\x1b[1m  -- BLOCK: one box each time the window fills --\x1b[0m")
	for i in 1 ..= 15 do mn.info("count = %d", i)
	mn.reset_ctx() // settles the partial 13-15 block, or those rows would be lost
}

long_line_modes :: proc() {
	section(
		"truncate_long_lines :: rows wider than the terminal",
		"TRUNCATE: one row ending in an ellipsis. WRAP: several rows, all 300 chars kept",
	)
	baseline()
	mn.init(group_by_thread = true, grouped_logs_stream = false, show_location = false)

	huge := strings.repeat("X", 300)
	defer delete(huge)

	mn.init(truncate_long_lines = true)
	fmt.printfln("\x1b[1m  -- TRUNCATE (default) --\x1b[0m")
	mn.info("short")
	mn.warn("massive: %s", huge)
	mn.reset_ctx()

	mn.init(truncate_long_lines = false)
	fmt.printfln("\x1b[1m  -- WRAP --\x1b[0m")
	mn.info("short")
	mn.warn("massive: %s", huge)
	mn.reset_ctx()

	fmt.printfln("\x1b[1m  -- WRAP keeps color across the break --\x1b[0m")
	pink := strings.repeat("M", 220)
	defer delete(pink)
	mn.info("%s%s%s", mn.MAGENTA, pink, mn.RESET)
	mn.reset_ctx()
}

box_width_modes :: proc() {
	section(
		"force_box_term_width :: box sizing",
		"DYNAMIC: the tiny box is narrow. FORCED: both boxes span the whole terminal",
	)
	baseline()
	mn.init(group_by_thread = true, grouped_logs_stream = false, show_location = false)

	mn.init(force_box_term_width = false)
	fmt.printfln("\x1b[1m  -- DYNAMIC (default): each box fits its own content --\x1b[0m")
	wide_then_narrow()

	mn.init(force_box_term_width = true)
	fmt.printfln("\x1b[1m  -- FORCED: rails land in the same column every time --\x1b[0m")
	wide_then_narrow()
	mn.init(force_box_term_width = false)
}

wide_then_narrow :: proc() {
	mn.info("a reasonably long row so this first box has some width to it")
	mn.info("second row, also longish, keeps the box wide")
	mn.reset_ctx()
	mn.info("tiny")
	mn.debug("also tiny")
	mn.reset_ctx()
}

context_reset :: proc() {
	section(
		"reset_ctx + ctx_reset :: closing a window on purpose",
		"3 separate boxes - the window is cut before each new pair of lines",
	)
	baseline()
	mn.init(group_by_thread = true, group_max_lines = 20, show_location = false)

	mn.info("box one, row one")
	mn.info("box one, row two")

	mn.reset_ctx() // explicit call
	mn.info("box two, row one")
	mn.info("box two, row two")

	// or piggyback on any log call instead of a separate statement
	mn.info("box three - opened by ctx_reset on this very line", ctx_reset = true)
	mn.info("box three, row two")
	mn.reset_ctx()
}

/***************************************************************************************************
 * threads and the core:log bridge
***************************************************************************************************/

worker :: proc(t: ^thread.Thread) {
	// UNCONDITIONAL and at the top level of the proc body. a fresh thread gets
	// the stock no-op logger, and `if ... do context.logger = ...` would
	// evaporate at the closing brace - context is BLOCK scoped.
	context.logger = mn.logger()

	log.infof("worker %d reporting in via core:log", t.user_index)
	mn.info("worker %d reporting in via muninn", t.user_index)
}

bridge :: proc() {
	section(
		"logger + hooked :: core:log rides the same pipeline",
		"hooked = true, 4 bridged lines, then boxed worker output - one box per thread id",
	)
	baseline()

	fmt.printfln("  hooked(context.logger) = %t", mn.hooked(context.logger))

	log.debug("core:log debug - same formatting, same gate, same sink")
	log.info("core:log info")
	log.warn("core:log warn")
	log.info("a stray 100%% and %s %d survive the bridge intact")

	mn.init(group_by_thread = true, group_max_lines = 4, show_location = false)
	threads: [3]^thread.Thread
	for i in 0 ..< len(threads) {
		t := thread.create(worker)
		t.user_index = i + 1
		threads[i] = t
		thread.start(t)
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
	mn.init(group_by_thread = false) // flushes any half-full box
}

/***************************************************************************************************
 * separators
***************************************************************************************************/

separators :: proc() {
	section(
		"sep + title :: dividers",
		"default sep, then char/color variants, then a raw ANSI code, then two titles",
	)
	baseline()

	mn.info("plain default separator next:")
	mn.sep()

	mn.info("char = \"-\", and a named color constant:")
	mn.sep(char = "-", color = mn.YELLOW)

	mn.info("nl_pre and nl_post pad it with blank lines:")
	mn.sep(char = "=", color = mn.CYAN, nl_pre = true, nl_post = true)

	// color is just a string, so any raw ANSI escape works - not only the
	// mn.RED / mn.GREEN / ... constants. this one is 256-color orange.
	mn.info("color takes a raw ANSI code too, e.g. orange 38;5;208:")
	mn.sep(char = "~", color = "\x1b[38;5;208m")

	mn.info("title = sep, your message, sep:")
	mn.title("named color", char = "-", color = mn.MAGENTA)
	mn.title("raw code", char = ".", color = "\x1b[38;5;120m")
}

/***************************************************************************************************
 * [ deep nested errors ]
***************************************************************************************************/

lvl_12 :: proc() {
	mn.error("nested 12 layers in: should see a truncation in the trace")
}
lvl_11 :: proc() {lvl_12()}
lvl_10 :: proc() {lvl_11()}
lvl_09 :: proc() {lvl_10()}
lvl_08 :: proc() {lvl_09()}
lvl_07 :: proc() {lvl_08()}
lvl_06 :: proc() {lvl_07()}
lvl_05 :: proc() {lvl_06()}
lvl_04 :: proc() {lvl_05()}
lvl_03 :: proc() {lvl_04()}
lvl_02 :: proc() {lvl_03()}
lvl_01 :: proc() {lvl_02()}
deep_nested_error :: proc() {
	section(
		"deeply nested stack trace",
		"being packed deep you should see `... [ TRUNCATED SEE LOGS FOR FULL TRACE ] ... ` " +
		"in the log denoting that is is hiding the middle to prevent terminal blowout",
	)

	lvl_01()
}
