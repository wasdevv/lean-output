// The session.compact adapter: a pipe, and a fail-safe.
//
// Everything this plugin decides is decided in Ruby — the vault, the ledger and
// the four hundred examples that hold them live there, and a second copy of
// that reasoning in a second language is a second thing to get wrong. So this
// file carries no policy at all. It hands the transcript to `bin/compact`,
// takes back what that prints, and on anything unexpected calls `next(e)`,
// which is the host compacting exactly as it would without the plugin.
//
// Requires Claude Code >= 2.1.274 and CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1. An
// older host ignores the `modules` key and keeps the command hooks, which are
// the whole plugin as it shipped before this file existed.

// Ruby's own startup, measured on this hook's sibling: 8ms without RubyGems
// against 45ms with. This runs once per compaction rather than once per tool
// call, so the flag buys little here — it is kept so both entry points are
// launched the same way and neither can drift into needing gems.
const TIMEOUT_MS = 20000;

// Below this the rewrite is not worth having: the host's summary reclaims far
// more, and returning a barely-shorter transcript spends a compaction to save
// nothing. Measured in messages because that is what the host counts back.
const MIN_REMOVED = 1;

// Auto-compaction is off unless asked for, and that is a measurement, not
// caution. `lean compaction` replays this machine's own transcripts: the three
// rules reach 8.9% of the pairs they are allowed to touch. Compacting earlier
// than the host would therefore buys a small pruning and pays the host's full
// summarisation sooner — a trade nothing here can show is worth making by
// default. Set LEAN_OUTPUT_COMPACT_AT to a percentage to turn it on.
//
// Re-measure before changing this. The number moves when the rules do.
// The name is spelled inline below because the host scans this file for the
// variables it reads, and a scanner cannot follow a constant.

// $.session.compact() triggers the event this module also hooks. The guard is
// taken before the first await and released in `finally`, so two turns
// completing together cannot start two compactions.
let compacting = false;

export function register(on) {
  on("session.compact", compact);
  on("turn.complete", maybeCompact);
}

async function maybeCompact($, e, next) {
  if (compacting) return next(e);
  compacting = true;
  try {
    const at = Number(await $.env.get("LEAN_OUTPUT_COMPACT_AT"));
    // Unset, empty, or nonsense reads as off. A misconfigured threshold must
    // never compact a session the user did not ask to have compacted.
    if (!Number.isFinite(at) || at <= 0 || at > 100) return next(e);

    const usage = await $.session.usage();
    // { context: { tokens, window, percent } } — and percent is absent before
    // the first turn has any input tokens at all.
    const percent = usage?.context?.percent;
    if (typeof percent !== "number" || percent < at) return next(e);

    await log($, `context at ${Math.round(percent)}% (>= ${at}%), compacting`);
    await $.session.compact();
  } catch {
    // A turn that cannot read its own usage is a turn that ends normally.
  } finally {
    compacting = false;
  }
  return next(e);
}

async function compact($, e, next) {
  const before = Array.isArray(e.messages) ? e.messages.length : 0;
  if (before === 0) return next(e);

  let out = "";
  try {
    const root = await $.env.get("CLAUDE_PLUGIN_ROOT");
    if (!root) return next(e);
    // session.compact carries no session id, and the vault needs one to know
    // which directory a spilled call belongs to.
    const id = await $.session.id();
    const run = await $.process.run(
      ["ruby", "--disable=gems", `${root}/bin/compact`],
      {
        stdin: JSON.stringify({ session_id: id, messages: e.messages }),
        timeoutMs: TIMEOUT_MS,
      },
    );
    // { exitCode, stdout, stderr }. A non-zero exit is a process that did not
    // finish its answer, and half a transcript is worse than none.
    if (run?.exitCode !== 0) return next(e);
    out = typeof run.stdout === "string" ? run.stdout.trim() : "";
  } catch {
    return next(e);
  }

  // Empty stdout is `bin/compact` declining, which it does for every error it
  // meets as well as for a transcript with nothing to take out.
  if (out === "") return next(e);

  let messages;
  try {
    messages = JSON.parse(out).messages;
  } catch {
    return next(e);
  }

  // The host validates this too and would reject the whole hook; checking here
  // means a bad answer costs the native summary rather than the compaction.
  if (!Array.isArray(messages) || messages.length === 0) return next(e);
  if (before - messages.length < MIN_REMOVED) return next(e);

  await log($, `${before} → ${messages.length} messages`);
  return { messages };
}

async function log($, text) {
  try {
    await $.ui.log({ text: `[lean-output] compaction: ${text}` });
  } catch {
    // A hook that cannot write to the log still has a transcript to return.
  }
}
