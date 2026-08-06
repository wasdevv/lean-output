---
description: Show or switch the lean-output compression level for this directory
argument-hint: "[off|safe|full|ultra|volatile]"
allowed-tools: Bash(ruby:*)
---

!`ruby "${CLAUDE_PLUGIN_ROOT}/bin/lean" $ARGUMENTS`

Report the output above verbatim and stop. Do not explain it, do not run
anything else, do not offer to change any files.

The level takes effect on the next tool call — the hook reads the flag fresh
every time, so nothing needs restarting.
