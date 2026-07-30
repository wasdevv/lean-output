# lean-output

**A Claude Code plugin that compresses RSpec, RuboCop, Brakeman and `git diff` outputs before they reach the model — fewer tokens, zero lost failures.**

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
| brakeman — 5 warnings | 3041 → 631 | 760 → 155 | **-79%** |
| brakeman — warnings (ANSI) | 3811 → 631 | 953 → 155 | **-83%** |
| brakeman — clean scan | 1922 → 66 | 481 → 16 | **-97%** |
| git show — vendored deps | 62600 → 9700 | 15642 → 2416 | **-85%** |
| git show — no generated | 4886 | 1215 | passthrough² |
| cargo — 4 errors | 1513 → 833 | 378 → 207 | **-45%** |
| cargo — 4 errors (ANSI) | 2390 → 833 | 598 → 207 | **-65%** |
| cargo — 7 warnings | 1698 → 1024 | 425 → 256 | **-40%** |
| cargo — warnings (ANSI) | 2575 → 1024 | 644 → 256 | **-60%** |
| cargo — clean build | 120 | 30 | passthrough² |

¹ estimate (chars / 4); run `ANTHROPIC_API_KEY=... bin/bench` for exact counts via the `count_tokens` API.
² Untouched: small outputs are never rewritten.

Cargo compresses less than the Ruby tools, and that is the correct outcome: rustc diagnostics are mostly signal already. What goes away is the ASCII art — the echoed source line, the caret runs, the suggestion diffs — while every `file:line:col` and every `note:`/`help:` stays. On colored output the win doubles, because escape sequences are a third of the bytes.

The benchmark enforces three invariants, and fails the build on any of them:

1. **Zero loss** — every failure/offense `file:line`, every rustc `--> file:line:col`, and every changed file path in the original must appear in the compressed output.
2. **No vacuous passes** — a fixture that is supposed to contain failures must actually yield locations to the extractor. Without this, a broken extractor would make invariant 1 pass trivially.
3. **Negative corpus** — five inputs that must come back *untouched*: libtest results, `--message-format=json`, `-f json`, genuinely ambiguous chained commands, and output below the line threshold.

Diffs are where the numbers get absurd, because a single vendored dependency dwarfs everything a reviewer actually reads. The full commit the fixture above was sliced from (a CodeMirror 6 vendoring: 29 files, 233 hand-written insertions) goes from **651,833 B to 13,247 B — -97%**, roughly **163k tokens down to 3.3k**. Uncompressed it does not fit in a review at all.

## Install

```
/plugin marketplace add wasdevv/lean-output
/plugin install lean-output@lean-output
```

Requires Ruby ≥ 3.0 on your PATH. The hook runs on pure stdlib — no gems, no Bundler, no measurable startup cost.

## How it works

Hooks on `PostToolUse` **and** `PostToolUseFailure` intercept every Bash tool result — the failure event matters most, since a failing suite exits nonzero and never reaches `PostToolUse`. A detector matches the command (`rspec` / `rubocop` / `brakeman` / `git diff|show` / `cargo`) **and** sniffs the output for the tool's summary line — both must agree, otherwise nothing happens. When a compressor applies:

- **RSpec** — keeps the summary, every failure (description, `Failure/Error` source, expectation/exception message, first project frame, rerun location). Drops dots, seeds, profiling, coverage noise, gem/support frames and diff blocks.
- **RuboCop** — keeps the summary and every offense location, grouped by file and deduped by cop/message (`3:1, 7:2, 9:5 Layout/TrailingWhitespace: ...`). Drops code excerpts, carets and progress output.
- **Brakeman** — keeps the warning count and every warning (line, confidence, category, message, vulnerable code) grouped by file. Drops the progress log, the ~1kB "Checks Run" list and the report boilerplate.
- **git diff / git show** — passes every hand-written hunk through **byte for byte**, and collapses the body of generated files to one line (`[lean-output] generated file — +12/-3 lines, body collapsed`), keeping their `diff --git` header so nothing disappears silently. Collapsed: `vendor/`, `node_modules/`, `dist/`, `coverage/`, `app/assets/builds/`, lockfiles (`Gemfile.lock`, `Cargo.lock`, `package-lock.json`, `yarn.lock`, `go.sum`, …), `db/structure.sql`, `*.min.js|css` and source maps. **`db/schema.rb` is deliberately not collapsed** — it is how a Rails reviewer sees what a migration actually did.
- **cargo** (`build`, `check`, `clippy`, `test`, `run`) — keeps the diagnostic count, and for each one the `error[CODE]`/`warning` header, its `--> file:line:col`, the caret labels (the text that explains *why*, e.g. `expected i32, found &str`) and every `note:`/`help:`. Drops the echoed source lines, the caret art itself, suggestion diffs and `Compiling`/`Finished` progress. Refuses to touch output that carries **libtest results** (`running N tests`, `test result:`) or a successful `cargo run`, because panic sites and program stdout are not rustc art and cannot be rebuilt.

## Fail-safe by design

Compression is only worth it if it can never hurt you:

- **Passthrough on any doubt** — unrecognized format, output under 40 lines, missing summary (truncated output), `--format json` already in use, ambiguous chained commands: the original output stays untouched.
- **Failures are sacred** — every failing example and its `file:line` survives compression, always.
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
