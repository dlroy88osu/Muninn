package main

import mn "../.."
import "core:fmt"
import "core:thread"


THREADS :: 5
ITERS :: 200

worker :: proc(id: int) {
	defer free_all(context.temp_allocator)

	for i in 0 ..< ITERS {
		mn.trace("t%d trace %d", id, i, ctx_reset = true)
		mn.debug("t%d debug %d", id, i)
		mn.info("t%d info  %d", id, i)
		mn.warn("t%d warn  %d", id, i)
		mn.error("t%d error %d", id, i) // pulls a stack trace under ODIN_DEBUG

		if i % 50 == 0 do free_all(context.temp_allocator)
	}
}

main :: proc() {
	mn.title("muninn threaded test")

	mn.init(group_by_thread = true)

	threads: [THREADS]^thread.Thread
	for i in 0 ..< THREADS {
		threads[i] = thread.create_and_start_with_poly_data(i, worker)
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	mn.flush()
	mn.sep(char = "-", color = "\x1b[38;5;77m", nl_pre = true, nl_post = true)
	fmt.printfln(
		"done: %d threads x %d iters = %d lines expected",
		THREADS,
		ITERS,
		THREADS * ITERS * 5,
	)
}
