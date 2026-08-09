package main

import mn "../.."
import "core:os"


// small helper so each section is obvious in the scrollback
sec :: proc(msg: string) {
	mn.sep(char = "=", color = mn.CYAN, nl_pre = true)
	mn.title(msg, char = "-", color = mn.CYAN)
}


main :: proc() {

	mn.title("muninn init test")

	// ------------------------------------------------------------------ level
	sec("level")
	mn.init(level = .TRACE)
	mn.trace("VISIBLE - level=TRACE, so trace passes")
	mn.debug("VISIBLE - level=TRACE")

	mn.init(level = .WARN)
	mn.trace("HIDDEN - you should NOT see this (level=WARN)")
	mn.debug("HIDDEN - you should NOT see this (level=WARN)")
	mn.info("HIDDEN - you should NOT see this (level=WARN)")
	mn.warn("VISIBLE - warn >= WARN")
	mn.error("VISIBLE - error > WARN")

	mn.init(level = .INFO)
	mn.info(
		"back to level=INFO - if you saw exactly one warn above and no trace/debug/info, level works",
	)


	// ------------------------------------------------------------------ formatting toggles
	sec("show_timestamp")
	mn.init(show_timestamp = true)
	mn.info("leading [ YYYY-MM-DD HH:MM:SS ] should be present")
	mn.init(show_timestamp = false)
	mn.info("no timestamp on this line")

	sec("show_runtime")
	mn.init(show_runtime = true)
	mn.info("leading [ HH:MM:SS ] elapsed-since-start should be present")
	mn.init(show_runtime = false)
	mn.info("no runtime on this line")

	sec("show_location / short_location")
	mn.init(show_location = true, short_location = true)
	mn.info("trailing location should read 'main.odin:NN ( main )'")
	mn.init(short_location = false)
	mn.info("trailing location should now be the FULL path to main.odin")
	mn.init(show_location = false)
	mn.info("no location at all on this line")
	mn.init(show_location = true, short_location = true)

	sec("show_pid / show_tid")
	mn.init(show_pid = true, show_tid = true)
	mn.info("trailing :: ( process_id = N | thread_id = N )")
	mn.init(show_pid = true, show_tid = false)
	mn.info("process_id only")
	mn.init(show_pid = false, show_tid = true)
	mn.info("thread_id only")
	mn.init(show_pid = false, show_tid = false)
	mn.info("neither id on this line")

	sec("use_color")
	mn.init(use_color = false)
	mn.info("this line should be plain text - no ANSI escapes anywhere")
	mn.init(use_color = true)
	mn.info("color is back - level tag and location should be tinted again")


	// ------------------------------------------------------------------ emit_json
	sec("emit_json")
	mn.info("pretty line - about to switch to raw json on stdout")
	mn.init(emit_json = true)
	mn.info("this line prints as a single json object, not a pretty line")
	mn.init(emit_json = false)
	mn.info("pretty formatting restored")


	// ------------------------------------------------------------------ file sink
	sec("save_file / log_dir")
	custom := "./demo_logs"
	mn.init(save_file = true, log_dir = custom)
	mn.info("this line should land in %s as a .jsonl", custom)
	mn.flush() // force the 32KB buffer out so the file is on disk right now

	if os.exists(custom) {
		mn.info("PROVED - directory %s exists on disk", custom)
	} else {
		mn.error("FAILED - %s was not created", custom)
	}

	mn.init(save_file = false)
	mn.info("save_file=false - this line is console-only, nothing written to disk")
	mn.init(save_file = true) // reopens the same path


	// ------------------------------------------------------------------ rotate_days
	sec("rotate_days")
	mn.init(rotate_days = 2)
	mn.info("rotate_days=2 - only provable at exit, @(fini) prunes anything older")


	// ------------------------------------------------------------------ grouping (do this LAST)
	// grouping DEFERS output: nothing prints until a box closes. With
	// group_max_lines=3 you should get two complete boxes below.
	sec("group_by_thread / group_max_lines")
	mn.init(group_by_thread = true, group_max_lines = 3, show_tid = false)

	mn.info("box 1 - line 1")
	mn.info("box 1 - line 2")
	mn.info("box 1 - line 3") // hits the cap -> box 1 closes and prints here
	mn.info("box 2 - line 1")
	mn.info("box 2 - line 2") // still buffered...

	mn.info("box 2 - line 3, ctx_reset next")
	mn.info("box 3 - fresh context", ctx_reset = true) // closes box 2 early

	mn.flush() // drains whatever is still pending
	mn.init(group_by_thread = false)


	sec("done")
	mn.info("all options exercised")
}
