# frozen_string_literal: true

require 'spec_helper'

# `volatile` is two rungs the other levels do not have, and they answer
# different questions about the same result.
#
# The vault answers "does this have to be in the context window at all" — the
# bytes go to a file and come back as their two ends and a path, losing
# nothing. The ceiling answers "how big may a rewrite be" and is the only place
# in this plugin where content is actually discarded, so it applies to what a
# compressor already distilled and never to raw output the vault can keep.
#
# The case for both is the shape of the corpus: over 8745 real results the
# largest 10% of calls hold 50.1% of the bytes and the median is 1261B. The
# vault takes that corpus to -65%, the ceiling alone to -22%, compressors -6%.
RSpec.describe 'the volatile level' do
  # A fresh session per call by default, so one example's spills cannot make the
  # next one's look like repeats. Anything asserting what the plugin says the
  # *second* time has to pass a fixed id — that is the whole subject there.
  def bash(command, output, level: 'volatile', session: "volatile-#{rand(1 << 32)}")
    ENV['LEAN_OUTPUT_MODE'] = level
    LeanOutput::Runner.call(
      'session_id' => session,
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => command },
      'tool_response' => { 'stdout' => output, 'stderr' => '' }
    )&.dig('hookSpecificOutput', 'updatedToolOutput', 'stdout')
  end

  around do |example|
    previous = ENV.fetch('LEAN_OUTPUT_MODE', nil)
    Dir.mktmpdir('volatile') do |dir|
      ENV['LEAN_OUTPUT_STATE_DIR'] = dir
      example.run
    end
    ENV['LEAN_OUTPUT_MODE'] = previous
  end

  let(:long) { (1..4000).map { |n| "line #{n} of something incompressible #{n * 7919}" }.join("\n") }

  def vault_path(text)
    text[/full text at (\S+)/, 1]
  end

  describe 'the vault' do
    it 'leaves a result that is cheaper to carry than to point at' do
      expect(bash('echo hi', "small\n" * 3)).to be_nil
    end

    it 'replaces a long unclaimed result with its ends and a path' do
      pointer = bash('cat big.log', long)

      expect(pointer.bytesize).to be < 1_500
      expect(pointer).to include('line 1 of something')
      expect(pointer).to include('line 4000 of something')
      expect(pointer).not_to include('line 2000 of something')
    end

    # The whole difference between this rung and the ceiling: nothing was
    # destroyed, so the middle is a Read away rather than gone.
    it 'writes the original byte for byte where it says it did' do
      path = vault_path(bash('cat big.log', long))

      expect(File.read(path)).to eq(long)
    end

    # The trust boundary, and the whole of it: something was withheld, this
    # much of it, and it is at that path. Said on every spill, so anything
    # beyond those three facts is paid for thousands of times.
    it 'tells the model how to get the middle back' do
      pointer = bash('cat big.log', long)

      expect(pointer).to include('middle withheld')
      expect(pointer).to match(/full text at \S+ \(Read or grep it\)/)
    end

    # The preview's tail is aligned to a line break, which is worth bytes on a
    # log and would be worth the whole tail on a result that has no break to
    # align to — an MCP row set, a minified file. Those get the raw slice.
    it 'still ends a single-line result with its own last bytes' do
      pointer = bash('psql -c "select …"', "id,name,#{'x' * 4000},END")

      expect(pointer).to include("END\n[lean-output] middle withheld")
    end

    it 'spills a Read the same way it spills a Bash result' do
      ENV['LEAN_OUTPUT_MODE'] = 'volatile'
      result = LeanOutput::Runner.call(
        'session_id' => 'volatile-read', 'tool_name' => 'Read',
        'tool_input' => { 'file_path' => '/tmp/big.rb' },
        'tool_response' => { 'type' => 'text',
                             'file' => { 'filePath' => '/tmp/big.rb', 'content' => long } }
      )

      content = result.dig('hookSpecificOutput', 'updatedToolOutput', 'file', 'content')
      expect(File.read(vault_path(content))).to eq(long)
    end

    # A compressed result is distilled signal. Hiding *that* behind a pointer
    # would put the failures someone is about to read one tool call further
    # away, and the bytes it replaced are already gone.
    it 'never spills what a compressor claimed' do
      rspec = File.read('spec/fixtures/rspec_failures.txt')
      pointer = bash('bundle exec rspec', rspec)

      expect(pointer).not_to include('middle withheld')
      expect(pointer).to include('rspec ./')
    end

    # Rung 2 turned on the plugin's own prose. The explanation of what a
    # lean-output path is does not change between spills, and at this level it
    # was being paid once per spill — 3824 times over 32 real sessions.
    describe 'the second time it has to say the same sentence' do
      def spill(name, body) = bash("cat #{name}", body, session: 'prose-spec')

      it 'explains once and then stops explaining' do
        first = spill('a.log', long)
        second = spill('b.log', "#{long}b")

        expect(first).to include('middle withheld').and include('(Read or grep it)')
        expect(second).to include('withheld')
        expect(second).not_to include('(Read or grep it)')
        expect(second.bytesize).to be < first.bytesize
      end

      # The line this rung must not cross. Prose is what gets shortened; the
      # locator is content, and a pointer that cannot be resolved is the one
      # failure this plugin exists to avoid. Both forms are read back here.
      it 'hands out a path that resolves in either form' do
        first = spill('a.log', long)
        second = spill('b.log', "#{long}b")

        expect(File.read(vault_path(first))).to eq(long)
        expect(File.read(vault_path(second))).to eq("#{long}b")
      end

      # Both forms say it the same way on purpose: three rungs hand out paths —
      # this one, the ceiling and the ledger — and one shape between them is
      # worth more than the fifteen bytes a bespoke terse form would save.
      it 'keeps `full text at` as the one way any rung hands out a path' do
        pointers = [spill('a.log', long), spill('b.log', "#{long}b")]

        expect(pointers).to all(match(/full text at \S+/))
      end

      it 'explains again once the earlier explanation may have been compacted away' do
        spill('a.log', long)
        ENV['LEAN_OUTPUT_WINDOW'] = '1'

        expect(spill('c.log', "#{long}c")).to include('(Read or grep it)')
      ensure
        ENV.delete('LEAN_OUTPUT_WINDOW')
      end
    end

    it 'is off at every level below volatile' do
      expect(bash('cat big.log', long, level: 'ultra')).to be_nil
      expect(bash('cat big.log', long, level: 'full')).to be_nil
    end

    # KEEP bounds the files inside one session and used to be the whole story,
    # which left the number of sessions unbounded — the shape of leak that
    # reads as working for months and then as a full disk.
    it 'keeps the number of session directories bounded' do
      (LeanOutput::Vault::SESSIONS + 5).times { bash('cat big.log', long) }

      expect(LeanOutput::Vault.sessions.size).to eq(LeanOutput::Vault::SESSIONS)
    end

    # The pointer names one result; this is how the other 399 stay findable.
    # Membership, not order: two spills a millisecond apart tie on directory
    # mtime, so `sessions` orders by a clock too coarse to promise more.
    it 'lists the session it wrote to' do
      path = vault_path(bash('cat big.log', long))

      expect(LeanOutput::Vault.sessions).to include(File.dirname(path))
    end
  end

  describe 'the ceiling' do
    it 'brings a rewrite that is still enormous under the cap' do
      text = 'x' * 20_000
      clipped = LeanOutput::Text.clip(text, LeanOutput::Mode::CAP_BYTES)

      expect(clipped.bytesize).to be <= LeanOutput::Mode::CAP_BYTES + 5
    end

    it 'exists only at volatile' do
      expect(LeanOutput::Mode::POLICY['ultra'][:cap]).to be_nil
      expect(LeanOutput::Mode::POLICY['volatile'][:cap]).to eq(LeanOutput::Mode::CAP_BYTES)
    end

    # The hole the benchmark found. A 53kB failing suite compresses to 8.5kB of
    # distilled failures, which the ceiling then cuts to 4kB — and the vault had
    # declined the raw output two lines earlier, precisely because a compressor
    # claimed it. Failures past the cut were unrecoverable from anywhere.
    it 'stores the original of a compressed result it has to cut' do
      # A real 21-failure run, not the 3-failure fixture repeated: repeats
      # compress away and never reach the ceiling, which is why this went
      # unnoticed. It takes a genuinely broad breakage to trigger, and by then
      # the failures past the cut are exactly what someone came to read.
      pointer = bash('bundle exec rspec', File.read('spec/fixtures/rspec_broad_failure.txt'))

      expect(pointer).to include('the middle is gone from here')
      expect(File.read(vault_path(pointer))).to include('705 examples, 21 failures')
    end

    it 'says so plainly when it had to cut with nowhere to store the original' do
      ENV['LEAN_OUTPUT_STATE_DIR'] = '/proc/nowhere-the-vault-can-write'
      pointer = bash('bundle exec rspec', File.read('spec/fixtures/rspec_broad_failure.txt'))

      expect(pointer).to include('re-run the command narrower')
      expect(pointer).not_to include('full text at')
    end
  end

  # The ledger and the vault both make a claim about the same result, and they
  # used to contradict each other. A spilled result was remembered under the
  # digest of its *original*, so the next occurrence came back as "900 lines
  # withheld" — bytes the model had never been given, with no path back to them.
  # Silent by construction: the model answers as if it had read the file.
  describe 'a repeat of a result that was only ever a pointer' do
    def read_big(session = 'pointer-repeat')
      ENV['LEAN_OUTPUT_MODE'] = 'volatile'
      LeanOutput::Runner.call(
        'session_id' => session, 'tool_name' => 'Read',
        'tool_input' => { 'file_path' => '/tmp/big.rb' },
        'tool_response' => { 'type' => 'text',
                             'file' => { 'filePath' => '/tmp/big.rb', 'content' => long } }
      )&.dig('hookSpecificOutput', 'updatedToolOutput', 'file', 'content')
    end

    it 'points at the vault instead of claiming the bytes are in the window' do
      read_big
      second = read_big

      expect(second).to include('byte-identical to Read /tmp/big.rb')
      expect(second).not_to include('withheld')
      expect(File.read(vault_path(second))).to eq(long)
    end

    # The reference itself writes no file, so the path has to survive being
    # remembered again — otherwise the third occurrence reintroduces the lie.
    it 'keeps the path across a chain of repeats' do
      3.times { read_big }

      expect(File.read(vault_path(read_big))).to eq(long)
    end

    # The other half of the invariant: when the earlier occurrence really did
    # arrive whole, "withheld" is the true and much cheaper thing to say.
    #
    # The size is the whole example. It has to sit above `min_bytes` to be
    # deduplicable at all and below `spill` so the vault declines it, and that
    # band is the only way to reach the ledger with nothing on disk behind it.
    # At `full`, where `spill` is nil, every size lands in the band and this
    # asserts nothing — which is what it did before the size was pinned.
    it 'still says withheld when the first occurrence was delivered whole' do
      ENV['LEAN_OUTPUT_MODE'] = 'volatile'
      small = "line one\nline two\n#{'filler ' * 40}\n"
      expect(small.bytesize).to be_between(LeanOutput::Mode::POLICY['volatile'][:min_bytes],
                                           LeanOutput::Mode::SPILL_BYTES)

      text = nil
      2.times do
        text = LeanOutput::Runner.call(
          'session_id' => 'delivered-repeat', 'tool_name' => 'Read',
          'tool_input' => { 'file_path' => '/tmp/small.rb' },
          'tool_response' => { 'type' => 'text',
                               'file' => { 'filePath' => '/tmp/small.rb', 'content' => small } }
        )&.dig('hookSpecificOutput', 'updatedToolOutput', 'file', 'content')
      end

      expect(text).to include('lines withheld')
      expect(text).not_to include('full text at')
    end

    # A pointer is the one thing here that can outlive what it names: the vault
    # evicts by directory past SESSIONS and by file past KEEP, and a repeat
    # refreshes the ledger entry without writing anything. Pointing at a deleted
    # file is worse than not deduplicating at all, so the result goes back down
    # the ladder and is spilled again.
    it 'declines to reference a vault file that has been evicted' do
      first = read_big
      FileUtils.rm_f(vault_path(first))

      second = read_big

      expect(second).not_to include('byte-identical')
      expect(File.read(vault_path(second))).to eq(long)
    end
  end

  describe 'reading back what was spilled' do
    # The pointer promises the content is still there. Compressing the read of a
    # vault path breaks that promise in the exact case the vault exists for, and
    # it breaks it twice over: the first read dedups against the spill it came
    # from, and every read after that dedups against the notice.
    it 'hands back a vault file whole, however many times it is read' do
      ENV['LEAN_OUTPUT_MODE'] = 'volatile'
      content = "marker\n#{'x' * 4_000}"
      path = File.join(LeanOutput::Vault.root, 'a1b2c3d4', '0001-cat-big.txt')

      2.times do
        result = LeanOutput::Runner.call(
          'session_id' => 'vault-readback', 'tool_name' => 'Read',
          'tool_input' => { 'file_path' => path },
          'tool_response' => { 'type' => 'text',
                               'file' => { 'filePath' => path, 'content' => content } }
        )

        expect(result).to be_nil
      end
    end

    it 'still compresses a read of the same size outside the vault' do
      ENV['LEAN_OUTPUT_MODE'] = 'volatile'
      content = "marker\n#{'x' * 4_000}"

      result = LeanOutput::Runner.call(
        'session_id' => 'vault-readback', 'tool_name' => 'Read',
        'tool_input' => { 'file_path' => '/tmp/not_the_vault.txt' },
        'tool_response' => { 'type' => 'text',
                             'file' => { 'filePath' => '/tmp/not_the_vault.txt',
                                         'content' => content } }
      )

      expect(result).not_to be_nil
    end
  end

  describe 'what the ceiling is allowed to cut' do
    # A ceiling is supposed to work the tail — chained commands and bulk row
    # sets. Every single-tool verdict in the corpus compresses to 1095B or
    # under, so none of them should ever meet CAP_BYTES. Lower the ceiling past
    # that line and it starts dropping failures out of a result someone is
    # about to read, silently: no other example here would notice.
    {
      'bundle exec rspec' => 'rspec_failures.txt',
      'cargo build' => 'cargo_warnings.txt'
    }.each do |command, fixture|
      it "leaves the verdict of `#{command}` whole" do
        result = bash(command, File.read("spec/fixtures/#{fixture}"))

        expect(result).not_to be_nil
        expect(result).not_to include('clipped to')
      end
    end
  end
end
