package main

import mn "../.."
import "core:os"

path := "c/:dev/my_app"
host := "127.0.0.1"
port := 22
delay := 15
err := "This is not good!!!"
ftl := "Ma Lord, we cannot cross this way!"

main :: proc() {
	mn.init(level = .DEBUG, log_dir = "C:/logs/myapp")

	mn.title("Muninn")

	mn.trace("cache warm: %d entries", 128)
	mn.debug("config loaded from %s", path)
	mn.info("listening on %s:%d", host, port)
	mn.warn("retrying in %v", delay)
	mn.error("connection dropped: %v", err)

	mn.sep(char = "-", color = mn.GRAY)

	mn.fatal("WTF happened: %v", ftl)

	// only if you bail out without returning from main
	mn.flush()
	os.exit(1)
}
