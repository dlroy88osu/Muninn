// examples/context_logger/main.odin
//
//   odin run . -debug      <- -debug so the stack trace boxes render
//
// THE RULE: `context` is BLOCK scoped, not proc scoped. an assignment inside an
// if / for / do / bare {} is thrown away at the closing brace. attach at the top
// level of the scope you want it in:
//
//     context.logger = mn.logger()
//
package main

import "core:fmt"
import "core:log"
import "core:thread"
import mn "../.."

step :: proc(n: int, name, expect: string) {
	fmt.printfln("\n\x1b[38;5;80m---[ %d. %s ]---\x1b[0m", n, name)
	fmt.printfln("\x1b[38;5;244m   expect: %s\x1b[0m", expect)
}

/***************************************************************************************************
 * a "third party lib" that has never heard of muninn - it only knows core:log
***************************************************************************************************/

vendor_thing :: proc() {
	log.debug("vendor: opening socket")
	log.info("vendor: connected")
	log.warn("vendor: retrying handshake")
	log.error("vendor: gave up") // >= ERROR gets a stack trace, same as mn.error
}

lvl_12 :: proc() {vendor_thing()}
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

worker :: proc(t: ^thread.Thread) {
	// UNCONDITIONAL, top level of the proc body. a fresh thread gets the stock
	// no-op logger, and `if ... do context.logger = ...` would evaporate.
	context.logger = mn.logger()

	log.infof("worker %d reporting in", t.user_index)
	log.warnf("worker %d is bored", t.user_index)
}

/***************************************************************************************************
 * main
***************************************************************************************************/

main :: proc() {
	mn.title("muninn <-> context.logger")

	// ---------------------------------------------------------------- 0: attach
	// read BEFORE we touch it, so we learn whether @(init) reached main.
	auto := mn.hooked(context.logger)

	// then attach unconditionally at main's top level - no if, no block.
	context.logger = mn.logger()

	fmt.printfln("AUTO HOOK (@(init) reached main): %t", auto)
	fmt.printfln("ATTACHED NOW:                     %t", mn.hooked(context.logger))

	mn.init(level = .TRACE)

	// ---------------------------------------------------------------- 1
	step(1, "core:log and muninn, one pipeline", "5 bridged lines, then 2 muninn lines (7 total)")

	log.debug("core:log debug")
	log.info("core:log info")
	log.warn("core:log warn")
	log.error("core:log error") // + stack box
	log.fatal("core:log fatal - does NOT abort, only log.panic does") // + stack box
	mn.info("...and we're still alive, see?")
	mn.trace("muninn-only trace level (core:log has no TRACE, .Debug is its floor)")

	// ---------------------------------------------------------------- 2
	step(2, "location passthrough", "4 lines, ALL tagged `main.odin:NN ( vendor_thing )`")

	controller()

	// ---------------------------------------------------------------- 3
	step(3, "mn level gates core:log too", "exactly 1 line: the log.warn")

	mn.init(level = .WARN)
	log.debug("DROPPED: core:log debug")
	log.info("DROPPED: core:log info")
	mn.info("DROPPED: muninn info - same gate, both sides")
	log.warn("KEPT: core:log warn")
	mn.init(level = .TRACE)

	// ---------------------------------------------------------------- 4
	step(4, "stray % doesn't detonate", "4 lines, no crash, no mangled text")

	log.info("raw 100% survives, so do %s %d %v")
	log.infof("core:log formatted: %d%% done", 42)
	mn.info("muninn formatted: %d%% done", 42)
	mn.info("muninn raw: a lone % stays put (no args = no fmt pass)")

	// ---------------------------------------------------------------- 5
	step(5, "bridged lines hit the json path", "2 raw json lines, no pretty formatting")

	mn.init(emit_json = true)
	log.info("this one is a json line")
	log.error("so is this, stack array and all")
	mn.init(emit_json = false)

	// ---------------------------------------------------------------- 6
	step(6, "threads + grouping", "4 boxes, 2 lines each, one per thread_id")

	mn.init(group_by_thread = true, group_max_lines = 2)

	threads: [4]^thread.Thread
	for i in 0 ..< len(threads) {
		t := thread.create(worker)
		t.user_index = i
		threads[i] = t
		thread.start(t)
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	mn.init(group_by_thread = false) // flushes any half-full boxes

	// ---------------------------------------------------------------- 7
	step(7, "detach / reattach", "DETACHED true, NO error line, then 1 line after reattach")

	// has to happen in YOUR scope, at YOUR top level. a mn.unhook() proc
	// physically cannot write your context - that's why there isn't one.
	context.logger = {}
	log.error("BUG: if you can read this, the detach didn't take")
	fmt.printfln("DETACHED: %t", !mn.hooked(context.logger))

	context.logger = mn.logger()
	log.info("re-hooked - back in business")

	mn.sep(char = "=", color = mn.GREEN, nl_pre = true)
	mn.info("done - check .logs/ for the jsonl")
}
