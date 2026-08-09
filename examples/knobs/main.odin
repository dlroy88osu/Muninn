package main

import mn "../.."

/*
init_demo shows both halves of the "call it once with everything, or call it
repeatedly to tweak one knob at a time" contract.

Phase 1 sets every option in a single call.
Phase 2 changes exactly one option per call, so each banner below shows the
literal call and the line under it shows the result.
*/
init_demo :: proc() {

	// ---------------------------------------------------------------- phase 1
	// everything, one call
	mn.title("init( ... everything, one call ... )", char = "=", color = mn.CYAN)

	mn.init(
		level = .TRACE,
		rotate_days = 5,
		emit_json = false,
		use_color = true,
		show_location = true,
		short_location = true,
		show_runtime = true,
		show_timestamp = true,
		show_pid = true,
		show_tid = true,
		group_max_lines = 50,
		group_by_thread = false,
		log_dir = "./demo_logs",
		save_file = true,
	)

	mn.trace("trace line")
	mn.debug("debug line")
	mn.info("info line")
	mn.warn("warn line")

	// ---------------------------------------------------------------- phase 2
	// one knob per call, watch the line shrink

	mn.title("init( show_timestamp = false )", char = "-", color = mn.CYAN)
	mn.init(show_timestamp = false)
	mn.info("wall clock is gone")

	mn.title("init( show_runtime = false )", char = "-", color = mn.CYAN)
	mn.init(show_runtime = false)
	mn.info("elapsed runtime is gone")

	mn.title("init( short_location = false )", char = "-", color = mn.CYAN)
	mn.init(short_location = false)
	mn.info("full source path instead of the basename")

	mn.title("init( show_location = false )", char = "-", color = mn.CYAN)
	mn.init(show_location = false)
	mn.info("no location at all")

	mn.title("init( show_pid = false )", char = "-", color = mn.CYAN)
	mn.init(show_pid = false)
	mn.info("process id is gone, thread id stays")

	mn.title("init( show_tid = false )", char = "-", color = mn.CYAN)
	mn.init(show_tid = false)
	mn.info("just the level and the message now")

	mn.title("init( use_color = false )", char = "-", color = mn.CYAN)
	mn.init(use_color = false)
	mn.info("plain text, no escapes")

	mn.title("init( use_color = true )", char = "-", color = mn.CYAN)
	mn.init(use_color = true)
	mn.info("color is back")

	// ------------------------------------------------- verbosity, live change

	mn.title("init( level = .WARN )", char = "-", color = mn.CYAN)
	mn.init(level = .WARN)
	mn.trace("dropped")
	mn.debug("dropped")
	mn.info("dropped")
	mn.warn("this one survives")

	mn.title("init( level = .TRACE )", char = "-", color = mn.CYAN)
	mn.init(level = .TRACE)
	mn.trace("everything is back")

	// ------------------------------------------------------ put the line back

	mn.title("init( show_location = true )", char = "-", color = mn.CYAN)
	mn.init(show_location = true)
	mn.info("location back on, everything else untouched")

	// ---------------------------------------------------------- output routing

	mn.title("init( emit_json = true )", char = "-", color = mn.CYAN)
	mn.init(emit_json = true)
	mn.info("pretty formatting is bypassed entirely")

	mn.title("init( emit_json = false )", char = "-", color = mn.CYAN)
	mn.init(emit_json = false)
	mn.info("back to the pretty line")

	mn.title("init( save_file = false )", char = "-", color = mn.CYAN)
	mn.init(save_file = false)
	mn.info("console only, file handle closed and flushed")

	mn.title("init( save_file = true )", char = "-", color = mn.CYAN)
	mn.init(save_file = true)
	mn.info("file handle reopened")

	mn.title("init( log_dir = \"./demo_logs/rerouted\" )", char = "-", color = mn.CYAN)
	mn.init(log_dir = "./demo_logs/rerouted")
	mn.info("new directory created, new PROG__DATE.jsonl opened")

	// ---------------------------------------------------------------- grouping

	mn.title("init( group_by_thread = true )", char = "-", color = mn.CYAN)
	mn.init(group_by_thread = true)
	mn.info("buffered, nothing printed yet")
	mn.info("still buffered")
	mn.info("still buffered")
	mn.reset_ctx() // closes this thread's box, box prints here

	mn.title("init( group_max_lines = 2 )", char = "-", color = mn.CYAN)
	mn.init(group_max_lines = 2)
	mn.info("box closes every two lines now")
	mn.info("so this one closes the box")
	mn.info("and this starts a fresh one")

	mn.title("init( group_by_thread = false )", char = "-", color = mn.CYAN)
	mn.init(group_by_thread = false) // flushes anything still pending
	mn.info("straight to the console again")

	// ------------------------------------------------------------------- done

	mn.title("done", char = "=", color = mn.CYAN)
	mn.flush()
}

main :: proc() {
	init_demo()
}
