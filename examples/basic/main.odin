package main

import mn "../.."

lvl_12 :: proc() {
	mn.trace("trace")
	mn.debug("debug")
	mn.info("info")
	mn.warn("warn")
	mn.error("error")

	// mn.fatal("This is a fatal failure")
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

controller :: proc() {
	lvl_01()
}


main :: proc() {
	mn.title("Muninn")
	mn.title(msg = "Startup", char = "-", color = mn.RED)
	mn.title(msg = "Shutdown", char = "=", color = "\x1b[38;5;77m")

	mn.sep()
	mn.sep(char = "-", color = mn.RED, nl_pre = true, nl_post = true)
	mn.sep(char = "=", color = "\x1b[38;5;77m")

	mn.init(
		show_timestamp = false,
		show_runtime = false,
		show_pid = false,
		show_tid = false,
		show_stack_trace = false,
	)

	mn.init(emit_json = true)

	mn.title("muninn minimal")

	mn.trace("trace message")
	mn.debug("debug message")
	mn.info("info message")
	mn.warn("warn message")
	mn.trace("trace message")
	mn.debug("debug message")
	mn.info("info message")
	mn.warn("warn message")
	mn.trace("trace message")
	mn.debug("debug message")
	mn.info("info message")
	mn.warn("warn message")
	mn.trace("trace message")
	mn.debug("debug message")
	mn.info("info message")
	mn.warn("warn message")
	mn.sep(char = "-", color = "\x1b[38;5;77m", nl_pre = true, nl_post = true)

	controller()
}
