---
description: Show or switch the lean-output compression level for this directory
argument-hint: "[off|safe|full|ultra|volatile|vault|analyze|readback|calibrate]"
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
