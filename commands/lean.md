---
description: Show or switch the lean-output compression level for this directory
argument-hint: "[off|safe|full|ultra|volatile|vault|analyze|readback|calibrate|trend|compare|unused|profile|audit|why|fixture|rescan]"
allowed-tools: Bash(ruby:*)
---

!`ruby "${CLAUDE_PLUGIN_ROOT}/bin/lean" $ARGUMENTS`

Report the output above verbatim and stop. Do not explain it, do not run
anything else, do not offer to change any files.

The level takes effect on the next tool call — the hook reads the flag fresh
every time, so nothing needs restarting.

`vault` lists what `volatile` spilled to disk, `analyze` replays your own
transcripts to say where the bytes are, and `readback` prices the spill floor
against how often the model followed a pointer. All three only print.

`calibrate` is the one that writes: it takes the floor at the top of that sweep
and stores it for this directory, with the date and the sample size behind it.
`uncalibrate` goes back to the default. It refuses, and says so, on a corpus
too small to answer.

`analyze` takes `--since <days>` and `--project <name>`, because one ranking
over every transcript ever written answers where the bytes *were*. `trend`
prints every calibration this directory has had, so a floor that keeps landing
on the same number can be told from one that is wandering.

`compare` replays the same corpus at every level and prints them side by side,
so picking a level stops being a week of switching and waiting. `unused` asks
the cheapest question on the ladder — did this output need to reach the model at
all — and answers it from what the model referred to later. It prints rather
than decides: output nothing refers to again measured 4.8% of the token-turns,
and deciding without quoting counts as unreferenced, so a high number is a
question about the agent's habits, not a verdict.

`profile` reports what the hook itself costs, which nothing here had ever
measured — set `LEAN_OUTPUT_PROFILE=1` first. Measured on this machine: 31ms per
tool call end to end, of which about 26ms is loading the library and 1ms is the
work — it was 71ms until the hook stopped launching with RubyGems. It is paid on every call whether or not anything is rewritten.

`why <file> [command]` says which gate declined a result — no compressor
recognised it, it was under the floor, or the rewrite did not save enough —
instead of leaving "unclaimed" to mean six things. `fixture <file> <name>`
captures real output into `spec/fixtures/`, which is the step every compressor
for a tool we do not support yet is actually blocked on.

`audit <path>` takes a path from a pointer and replays the ladder against the
stored original — what a compressor would drop, and whether every `file:line`
survived. `rescan` throws away the memo the scans keep per transcript, which is
the first thing to try when a number looks wrong.
