# lean-output

**A Claude Code plugin that compresses RSpec, RuboCop, Brakeman, `git diff`, cargo and `grep` outputs before they reach the model — fewer tokens, zero lost failures.**

Test suites are chatty. A single failing RSpec run ships progress dots, seeds, profiling tables, SimpleCov reports and gem backtraces into your context window — thousands of tokens the model doesn't need. lean-output rewrites those outputs on the fly via a `PostToolUse` hook, keeping **every failure, message and `file:line`** and dropping everything else.

Real capture from a live Claude Code session on **pipeline_hq**, a Rails 8 CRM — one failing spec in a 103-example suite went from **3.2kB to 346B**:

```text
BEFORE — what rspec printed (3.2kB)             AFTER — what the model received (346B)

Exit code 1                                     Exit code 1
                                                RSpec: 103 examples, 1 failure — Finished in 1.89 seconds
Randomized with seed 58159
F...........................................   1) LeanOutput e2e fixture fails on purpose  (rspec ./spec/lean_output_e2e_tmp_spec.rb:4)
                                                   Failure/Error: expect(User.new(email_address: "a@b.com").email_address).to eq("wrong@b.com")
Failures:                                          expected: "wrong@b.com"
  1) ...expectation + gem/support traces...        got: "a@b.com"
                                                   at ./spec/lean_output_e2e_tmp_spec.rb:5
Top 10 slowest examples (0.72675 seconds...
Top 8 slowest example groups ...                [lean-output] 3.2kB → 346B (-90%)
Coverage report generated for RSpec ...
103 examples, 1 failure
Failed examples: ...
```

**-90% of the bytes, 100% of the signal** — the model still pointed at the exact failing `file:line`.

## Benchmark

Measured on real outputs captured from a Rails 8 app (`bin/bench`):

| Scenario | Chars | Tokens¹ | Reduction |
|---|---|---|---|
| rspec — 3 failures | 4610 → 914 | 1153 → 228 | **-80%** |
| rspec — 3 failures (ANSI) | 6233 → 917 | 1558 → 228 | **-85%** |
| rspec — all passing | 2558 → 97 | 640 → 23 | **-96%** |
| rubocop — 13 offenses | 2122 → 631 | 531 → 157 | **-70%** |
| rubocop — offenses (ANSI) | 2671 → 631 | 668 → 157 | **-76%** |
| rubocop — clean run | 80 | 20 | passthrough² |
| brakeman — 5 warnings | 3041 → 632 | 760 → 155 | **-79%** |
| brakeman — warnings (ANSI) | 3811 → 632 | 953 → 155 | **-83%** |
| brakeman — clean scan | 1922 → 67 | 481 → 16 | **-97%** |
| git show — vendored deps | 62600 → 9700 | 15642 → 2416 | **-85%** |
| git show — no generated | 4886 | 1215 | passthrough² |
| cargo — 4 errors | 1513 → 833 | 378 → 207 | **-45%** |
| cargo — 4 errors (ANSI) | 2390 → 833 | 598 → 207 | **-65%** |
| cargo — 7 warnings | 1698 → 1024 | 425 → 256 | **-40%** |
| cargo — warnings (ANSI) | 2575 → 1024 | 644 → 256 | **-60%** |
| cargo — clean build | 120 | 30 | passthrough² |
| grep -rn — repeated paths | 3585 → 2578 | 896 → 644 | **-28%** |
| mcp query — 40 rows | 8450 → 2500 | 2113 → 625 | **-70%** |
| mcp query — enveloped | 9205 → 2500 | 2301 → 625 | **-73%** |
| chain — rspec+rubocop+brakeman | 9775 → 2106 | 2444 → 523 | **-78%** |
| chain — cargo+rspec | 6124 → 1713 | 1531 → 427 | **-72%** |
| chain — one segment, two tools | 6733 → 1510 | 1683 → 377 | **-78%** |
| chain — hidden by quoting | 6733 → 1510 | 1683 → 377 | **-78%** |
| chain — rspec + plain diff | 9497 → 5802 | 2368 → 1443 | **-39%** |
| rspec after a migration | 4737 → 1043 | 1184 → 260 | **-78%** |

¹ estimate (chars / 4); run `ANTHROPIC_API_KEY=... bin/bench` for exact counts via the `count_tokens` API.
² Untouched: small outputs are never rewritten.

Cargo compresses less than the Ruby tools, and that is the correct outcome: rustc diagnostics are mostly signal already. What goes away is the ASCII art — the echoed source line, the caret runs, the suggestion diffs — while every `file:line:col` and every `note:`/`help:` stays. On colored output the win doubles, because escape sequences are a third of the bytes.

The last six rows are one shell line running several tools into one buffer — see [Chains](#chains).

The benchmark enforces four invariants, and fails the build on any of them:

1. **Zero loss** — every failure/offense `file:line`, every rustc `--> file:line:col`, every changed file path and every grep hit in the original must appear in the compressed output. The file and the line are checked *apart*, not as one glued string: moving the path up into a header is allowed, losing either half is not.
2. **Nothing unclaimed disappears** — text no compressor recognised must come back byte for byte, so a migration that ran before the suite, or a diff with nothing to collapse, survives intact.
3. **No vacuous passes** — a fixture that is supposed to contain failures must actually yield locations to the extractor. Without this, a broken extractor would make invariant 1 pass trivially.
4. **Negative corpus** — seven inputs that must come back *untouched*: libtest results, `--message-format=json`, `-f json`, nested and multiline JSON values, a grep hit list where no path repeats, and output below the line threshold.

Diffs are where the numbers get absurd, because a single vendored dependency dwarfs everything a reviewer actually reads. The full commit the fixture above was sliced from (a CodeMirror 6 vendoring: 29 files, 233 hand-written insertions) goes from **651,833 B to 13,247 B — -97%**, roughly **163k tokens down to 3.3k**. Uncompressed it does not fit in a review at all.

## Install

```
/plugin marketplace add wasdevv/lean-output
/plugin install lean-output@lean-output
```

Requires Ruby ≥ 3.0 on your PATH. The hook runs on pure stdlib — no gems, no Bundler, no measurable startup cost.

## How it works

Hooks on `PostToolUse` **and** `PostToolUseFailure` intercept every Bash tool result — the failure event matters most, since a failing suite exits nonzero and never reaches `PostToolUse`. A detector matches the command (`rspec` / `rubocop` / `brakeman` / `git diff|show` / `cargo` / `grep|rg`) **and** sniffs the output for the tool's summary line — both must agree, otherwise nothing happens. When a compressor applies:

- **RSpec** — keeps the summary, every failure (description, `Failure/Error` source, expectation/exception message, first project frame, rerun location). Drops dots, seeds, profiling, coverage noise, gem/support frames and diff blocks.
- **RuboCop** — keeps the summary and every offense location, grouped by file and deduped by cop/message (`3:1, 7:2, 9:5 Layout/TrailingWhitespace: ...`). Drops code excerpts, carets and progress output.
- **Brakeman** — keeps the warning count and every warning (line, confidence, category, message, vulnerable code) grouped by file. Drops the progress log, the ~1kB "Checks Run" list and the report boilerplate.
- **git diff / git show** — passes every hand-written hunk through **byte for byte**, and collapses the body of generated files to one line (`[lean-output] generated file — +12/-3 lines, body collapsed`), keeping their `diff --git` header so nothing disappears silently. Collapsed: `vendor/`, `node_modules/`, `dist/`, `coverage/`, `app/assets/builds/`, lockfiles (`Gemfile.lock`, `Cargo.lock`, `package-lock.json`, `yarn.lock`, `go.sum`, …), `db/structure.sql`, `*.min.js|css` and source maps. **`db/schema.rb` is deliberately not collapsed** — it is how a Rails reviewer sees what a migration actually did.
- **grep / rg** — factors the repeated path out of a hit list: `app/services/agents/claude_code.rb:9:…` forty times becomes the path once, then `9: …` indented under it. Every line number and every matched line survives, and the `--` context separators and `grep: dir: Is a directory` notes stay where they were. Refuses a list where no path repeats, because a header per file would make the buffer *bigger*.
- **cargo** (`build`, `check`, `clippy`, `test`, `run`) — keeps the diagnostic count, and for each one the `error[CODE]`/`warning` header, its `--> file:line:col`, the caret labels (the text that explains *why*, e.g. `expected i32, found &str`) and every `note:`/`help:`. Drops the echoed source lines, the caret art itself, suggestion diffs and `Compiling`/`Finished` progress. Refuses to touch output that carries **libtest results** (`running N tests`, `test result:`) or a successful `cargo run`, because panic sites and program stdout are not rustc art and cannot be rebuilt.

## Chains

`bundle exec rspec && bundle exec rubocop && bin/brakeman -q` is one tool call and one buffer. So is `bin/rails db:migrate && bundle exec rspec`, where half the output belongs to no compressor at all.

Nothing here parses the command to work out where one tool stopped and the next began — quoting, wrapper scripts and `bash -c` make that a guess, and a wrong guess is silent data loss. Instead each compressor declares the lines only it writes, and from those claims a **span**: first recognised line to last, everything between included. It summarises that slice and nothing else; the rest of the buffer is spliced back untouched. Two spans that overlap is the one case with no honest answer — the tools disagree about who wrote those bytes — and it ends in passthrough.

The consequence is that a tool with nothing to say costs the buffer nothing. A `git diff` with no generated files to collapse used to force the whole chain to pass through; now it simply comes back verbatim beside a summarised rspec run.

Replayed over 301 real Bash results from local Claude Code transcripts: **-38% overall, and not one line outside a span went missing.** The whole-buffer rewrite this replaced scored -88% on the same corpus, but 138 of those results had silently deleted output the model never learned about.

The rule costs something, and it is worth naming. `rubocop --force-exclusion $(… | grep '\.rb$')` names grep in a subshell that only picks filenames and never writes to the buffer — but RuboCop's `file:line:col:` offenses have the exact shape of a grep hit, so both compressors claim, the spans overlap, and the buffer passes through. Measured over the corpus that is **one result in 249**. Letting the wider span win would recover it and would be right here, but it trades a rule for a heuristic, and the rule is what makes this predictable.

## What a rewrite has to be worth

A rewrite is only swapped in when it saves at least 30% — below that it isn't worth the risk of having thrown away the line the reader needed. Except that floor is really two charges in one: the footer has to pay for itself, *and* the saving has to be worth that risk.

Only the first applies to a compressor that discards nothing. Grep's regrouping keeps every line number and every matched line; there is no context to have lost. So a compressor declares whether it is lossless, and a lossless one clears **15%** instead of 30%. On the corpus, charging grep the full risk premium threw away 33 kB across 36 results that had discarded nothing to be suspicious of.

## Use it as a library

The hook is one caller. Anything that injects tool output into a prompt has the same problem and usually solves it with `byteslice`, which amputates whatever sits at the cut — typically the failure message the reader needed. `LeanOutput.compress` is the same engine behind a plain API:

```ruby
LeanOutput.compress(text, command: nil, budget: nil, footer: false) # => String
```

```ruby
gem "lean_output", github: "wasdevv/lean-output"
```

```ruby
# an agent orchestrator briefing a retry, instead of stdout.byteslice(0, 8_000)
LeanOutput.compress(stdout, command: "bundle exec rspec", budget: 8_000)
```

- **Always a String.** Passthrough returns the input itself; an unexpected error degrades to the input rather than raising. It drops in wherever you used to truncate.
- **`command` is optional.** Without it the text alone has to identify the tools, and each still only rewrites the span it recognises. Cargo never self-identifies — telling a rustc diagnostic from a successful `cargo run` followed by program stdout needs the subcommand.
- **`budget` is a byte ceiling spent on whole entries.** Compressed output is a summary plus blank-line-separated entries (one failure, one file's offenses, one diagnostic), so it keeps the summary and as many whole entries as fit, then says `[lean-output] 12 of 19 entries omitted (budget 8.0kB)`. For text no compressor understands it keeps both ends — the invocation and early errors at the head, the summary and exit status at the tail — and drops only the middle.
- **No line-count floor.** The hook's 40-line minimum and 30% minimum saving are policy in `Runner`; a caller asking for compression has already decided the text is too long.

Same thing from a shell, for callers that aren't Ruby:

```sh
bundle exec rspec 2>&1 | lean-output --command "bundle exec rspec" --budget 8000
```

Head to head on the fixture in this repo, against a 40-line tail — the shape most orchestrators reach for:

| | bytes | failure messages kept |
|---|---|---|
| original | 4610 | 3 of 3 |
| `lines.last(40)` | 1979 | **0 of 3** |
| `LeanOutput.compress` | 877 | 3 of 3 |

The tail keeps the profiling table and the coverage report and drops the entire `Failures:` section — the reader learns *which* specs failed, never *why*.

## Fail-safe by design

Compression is only worth it if it can never hurt you:

- **Passthrough on any doubt** — unrecognized format, output under 40 lines, missing summary (truncated output), `--format json` already in use, two compressors claiming the same bytes: the original output stays untouched.
- **Failures are sacred** — every failing example and its `file:line` survives compression, always.
- **Nothing is dropped in silence** — a compressor rewrites only the span it recognises; whatever else shared the buffer comes back byte for byte.
- **Errors can't break your session** — any exception inside the hook exits 0 silently.
- **Kill-switch** — `LEAN_OUTPUT_DISABLE=1` turns it off without uninstalling.
- Only rewrites when it saves at least 30%; a footer (`[lean-output] 4.5kB → 0.9kB (-80%)`) always tells the model — and you — that compression happened.

## Development

```sh
bundle install
bundle exec rspec   # golden tests over real captured fixtures — no mocks
bin/bench           # savings table + zero-loss check
```

Set `LEAN_OUTPUT_DEBUG=/some/file` to log every payload and compress/passthrough decision.

Troubleshooting: if the hook never fires, check that your project is trusted and that `.claude/settings*.json` files are valid — Claude Code silently disables hooks for untrusted projects and skips settings files that fail validation.

---

## Em português

**Plugin de Claude Code que comprime saídas de RSpec, RuboCop, Brakeman, `git diff` e `cargo` antes de chegarem ao modelo — menos tokens, nenhuma falha perdida.**

Saídas de suite de teste são verbosas: dots de progresso, seed, tabelas de profiling, relatório do SimpleCov, backtraces de gems. O lean-output reescreve essas saídas via hooks `PostToolUse`/`PostToolUseFailure`, preservando **toda falha, mensagem e `file:line`** e descartando o resto. Em sessão real no pipeline_hq (CRM Rails 8): suite de 103 exemplos com 1 falha foi de **3.2kB para 346B (-90%)** — e o modelo ainda apontou o `file:line` exato da falha. No benchmark: **80–96%** em RSpec, **70–76%** em RuboCop e **79–97%** em Brakeman (tabela acima).

O compressor de diff é o que mais economiza, porque uma dependência vendorada sozinha é maior que tudo que um revisor de fato lê. Hunk escrito à mão passa **byte a byte**; corpo de arquivo gerado (`vendor/`, lockfile, `app/assets/builds/`, `*.min.js`, source map) vira uma linha que ainda mostra o caminho e o `+N/-M`. Num commit real de vendoring do CodeMirror 6: **651.833 B → 13.247 B (-97%)**, de ~163k para ~3,3k tokens. `db/schema.rb` fica de fora de propósito — é o arquivo que mostra o que a migration realmente fez.

Instalação:

```
/plugin marketplace add wasdevv/lean-output
/plugin install lean-output@lean-output
```

Para Rust, o compressor de `cargo` guarda o cabeçalho de cada diagnóstico, o `--> file:line:col`, os rótulos que explicam o erro e os `note:`/`help:` — joga fora a arte ASCII (linha de código ecoada, carets, sugestões) e as linhas de progresso. Ele se **recusa** a mexer em saída com resultado de libtest (`running N tests`, `test result:`) ou em `cargo run` que compilou: panic e stdout do programa não são arte do rustc e não podem ser reconstruídos.

Princípios: em qualquer dúvida, passthrough (a saída original fica intacta); falhas e `file:line` nunca são perdidos (o `bin/bench` falha se isso acontecer); qualquer erro no hook sai silenciosamente sem quebrar a sessão; `LEAN_OUTPUT_DISABLE=1` desliga tudo.

Contribuições são bem-vindas — especialmente novos compressores do ecossistema Ruby/Rails (Minitest, `rails db:migrate`, backtraces genéricos...).

## License

MIT
