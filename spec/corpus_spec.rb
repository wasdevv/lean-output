# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe LeanOutput::Corpus do
  # A transcript line pairs a tool_use with the result that came back; the
  # response is stored under toolUseResult in the shape the host returned, which
  # is what makes the replay worth anything.
  def transcript(root, name, entries)
    dir = File.join(root, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'session.jsonl'), entries.map { |entry| JSON.generate(entry) }.join("\n"))
  end

  def call(id, tool, input)
    { 'sessionId' => 'abc', 'cwd' => '/repo',
      'message' => { 'role' => 'assistant',
                     'content' => [{ 'type' => 'tool_use', 'id' => id, 'name' => tool, 'input' => input }] } }
  end

  def result(id, response)
    { 'sessionId' => 'abc', 'cwd' => '/repo', 'toolUseResult' => response,
      'message' => { 'role' => 'user', 'content' => [{ 'type' => 'tool_result', 'tool_use_id' => id }] } }
  end

  def bash_response(stdout)
    { 'stdout' => stdout, 'stderr' => '', 'interrupted' => false,
      'isImage' => false, 'noOutputExpected' => false }
  end

  def grep_hits
    (1..60).flat_map { |i| (1..4).map { |j| "app/services/thing_#{i}.rb:#{j * 7}:  def call_#{j}" } }.join("\n")
  end

  around do |example|
    Dir.mktmpdir('lean-output-corpus-spec') { |dir| example.run(@root = dir) }
  end

  def analyze(root)
    described_class.analyze(root: root)
  end

  it 'pairs each tool_use with its result and measures what the hook would save' do
    transcript(@root, 'project-a', [call('t1', 'Bash', { 'command' => 'grep -rn "def " app/' }),
                                    result('t1', bash_response(grep_hits))])

    results = analyze(@root)

    expect(results.size).to eq(1)
    expect(results.first.command).to eq('grep')
    expect(results.first.saved).to be_positive
    expect(results.first.claimed).to be(true)
  end

  it 'groups a command family under one label so different arguments answer together' do
    entries = [%w[t1 rspec], %w[t2 rubocop]].flat_map do |id, sub|
      [call(id, 'Bash', { 'command' => "bundle exec #{sub}" }), result(id, bash_response("nothing\n" * 5))]
    end
    transcript(@root, 'project-a', entries)

    expect(analyze(@root).map(&:command).uniq).to eq(['bundle exec'])
  end

  # A prefix that survives the stripping becomes the label, and the whole ranking
  # is by label — so `cd X; rspec` ranked under a bucket called `cd`, which reads
  # as a command nothing could ever claim.
  it 'strips every shape of prefix before naming the command' do
    commands = ['cd /repo && bundle exec rspec', 'cd /repo; bundle exec rspec',
                'BUNDLE_GEMFILE=/repo/Gemfile bundle exec rspec',
                'cd /repo; RAILS_ENV=test timeout 60 bundle exec rspec']
    entries = commands.each_with_index.flat_map do |command, i|
      [call("t#{i}", 'Bash', { 'command' => command }), result("t#{i}", bash_response("nothing\n" * 5))]
    end
    transcript(@root, 'project-a', entries)

    expect(analyze(@root).map(&:command).uniq).to eq(['bundle exec'])
  end

  it 'counts a result no compressor claims as unclaimed rather than skipping it' do
    transcript(@root, 'project-a', [call('t1', 'Bash', { 'command' => 'echo hi' }),
                                    result('t1', bash_response('hi'))])

    results = analyze(@root)

    expect(results.size).to eq(1)
    expect(results.first.claimed).to be(false)
    expect(results.first.saved).to be_zero
  end

  # The whole point of the tool: ranking by what is left, not by what was saved,
  # so the line at the top is the one worth writing a compressor for.
  it 'ranks by the bytes still on the table' do
    small = [call('t1', 'Bash', { 'command' => 'grep -rn x app/' }), result('t1', bash_response(grep_hits))]
    big = (1..4).flat_map do |i|
      [call("e#{i}", 'Bash', { 'command' => 'echo something' }),
       result("e#{i}", bash_response('x' * 30_000))]
    end
    transcript(@root, 'project-a', small + big)

    report = described_class.report(analyze(@root))

    expect(report.lines[1]).to include('echo')
    expect(report).to match(/4 results|5 results/)
  end

  it 'leaves the live state directory alone while replaying' do
    live = ENV.fetch('LEAN_OUTPUT_STATE_DIR', nil)
    transcript(@root, 'project-a', [call('t1', 'Bash', { 'command' => 'grep -rn x app/' }),
                                    result('t1', bash_response(grep_hits))])

    analyze(@root)

    expect(ENV.fetch('LEAN_OUTPUT_STATE_DIR', nil)).to eq(live)
    expect(Dir.glob(File.join(live.to_s, '*.json'))).to be_empty
  end

  # The ranking is by label, so a label that names a shell prefix or a word from
  # a heredoc body ranks bytes under a command nobody ran.
  describe 'naming the command the ranking is about' do
    def label(command)
      described_class.label('tool_name' => 'Bash', 'tool_input' => { 'command' => command })
    end

    {
      'cd /repo && bundle exec rspec' => 'bundle exec',
      'cd /repo; bundle exec rspec' => 'bundle exec',
      'export PATH=/usr/bin:$PATH; mix test' => 'mix test',
      'RAILS_ENV=test bin/rails runner x' => 'bin/rails runner',
      'A=1 B=2 C= go test ./...' => 'go test',
      'cd /repo; A=1 env FOO=2 timeout 60 npm run build' => 'npm run',
      "python3 - <<'PY'\nimport json\nprint(json.dumps({}))\nPY" => 'python3',
      "cd /repo\nbundle exec rspec" => 'bundle exec',
      'cd /repo && ' => 'cd',
      'kubectl get pods' => 'kubectl get',
      'docker compose up' => 'docker compose',
      '/usr/local/bin/pytest -q' => 'pytest',
      'grep -rn "def " app/ | head -50' => 'grep',
      # A flag's value survives the syntax filter and used to land in the
      # family slot, naming one invocation instead of a family.
      'git -C /home/was/projetos/swarm status' => 'git status',
      %q(ruby -e 'puts LeanOutput::VERSION') => 'ruby',
      'bin/rails db:test:prepare' => 'bin/rails db:test:prepare',
      # `env -u NAME` takes a value, and the peel used to stop on it.
      'env -u BUNDLE_LOCKFILE BUNDLE_GEMFILE=$PWD/Gemfile bundle exec rspec' => 'bundle exec',
      # …but only a variable name. A command after a valueless flag survives.
      'env -i bundle exec rspec' => 'bundle exec'
    }.each do |command, expected|
      it "labels #{command.lines.first.strip} as #{expected}" do
        expect(label(command)).to eq(expected)
      end
    end

    it 'stops peeling instead of looping on a command that is all prefix' do
      expect(label('A=1 ' * 40)).to eq('A=1')
    end
  end

  # The line that separates "the compressors have nothing left" from "the
  # compressors never got a look".
  it 'says how much of the corpus trimmed itself before the hook saw it' do
    entries = [[call('t0', 'Bash', { 'command' => 'bundle exec rspec 2>&1 | tail -40' }),
                result('t0', bash_response("nothing\n" * 60))],
               [call('t1', 'Bash', { 'command' => 'bundle exec rspec' }),
                result('t1', bash_response("nothing\n" * 60))]]
    transcript(@root, 'project-a', entries.flatten(1))

    report = described_class.report(analyze(@root))

    expect(report).to include('50% of these commands trimmed their own output')
    expect(report).to include('1 of 2 calls')
  end

  it 'stays silent about trimming when nothing trimmed itself' do
    transcript(@root, 'project-a', [call('t1', 'Bash', { 'command' => 'echo hi' }),
                                    result('t1', bash_response('hi there'))])

    expect(described_class.report(analyze(@root))).not_to include('trimmed their own output')
  end

  # Ranking says which command left bytes behind; this says whether any rung
  # could have reached them. Same bounds as the runtime, read off the policy.
  describe 'the residual, by which rung can reach it' do
    # `volatile` is the only level with a vault, so it is the only one with a
    # third band — at `full` the report has two, which is the truth about what
    # `full` can reach.
    around { |example| described_class.send(:at_level, 'volatile') { example.run } }

    let(:policy) { LeanOutput::Mode.policy('volatile') }

    def report_for(*sizes)
      entries = sizes.each_with_index.flat_map do |size, i|
        [call("t#{i}", 'Bash', { 'command' => 'echo x' }), result("t#{i}", bash_response('x' * size))]
      end
      transcript(@root, 'project-a', entries)
      described_class.report(analyze(@root))
    end

    it 'shows only the bands the level actually has' do
      described_class.send(:at_level, 'full') do
        expect(report_for(500)).not_to include('over 15.6kB')
      end
    end

    it 'splits the residue at the ledger floor and the spill threshold' do
      report = report_for(policy[:min_bytes] - 1, policy[:min_bytes] + 10, policy[:spill] + 10_000)

      expect(report).to include('bytes still on the table')
      expect(report).to match(/under \S+\s+1 calls/)
      expect(report).to match(/#{Regexp.escape(LeanOutput::Text.human(policy[:min_bytes]))}–\S+\s+1 calls/)
      expect(report).to match(/over \S+\s+1 calls/)
    end

    it 'keeps an empty band visible rather than pretending it does not exist' do
      report = report_for(policy[:min_bytes] + 10)

      expect(report).to match(/under \S+\s+0 calls/)
      expect(report).to match(/over \S+\s+0 calls/)
    end

    # The column that stops the ranking reading as a roadmap: a band holding the
    # residue is only an opportunity if the bytes in it have something to take.
    it 'says how much of each band a readable rewrite could actually bank' do
      entries = [[call('t0', 'Bash', { 'command' => 'echo a' }),
                  result('t0', bash_response("the very same line of output\n" * 40))],
                 [call('t1', 'Bash', { 'command' => 'echo b' }),
                  result('t1', bash_response((1..40).map { |i| "unique line #{i} #{'x' * i}" }.join("\n")))]]
      transcript(@root, 'project-a', entries.flatten(1))

      report = described_class.report(analyze(@root))

      # The first band row is the empty one under the floor; the results landed
      # in the band above it.
      structure = report.scan(/(\d+)% structure/).flatten.map(&:to_i).max
      expect(structure).to be > 30
      expect(report).to include('deflate takes -')
    end

    it 'names deflate as a ceiling nobody collects rather than as a target' do
      report = report_for(4_000)

      expect(report).to include('not a collectable one')
    end

    # `Vault.spill` is `> spill` and `deduplicable?` is `>= min_bytes`, so a
    # result sitting exactly on a bound belongs to the band below it.
    it 'puts a result exactly on the spill threshold below it, where the runtime does' do
      report = report_for(policy[:spill])

      expect(report).to match(/over \S+\s+0 calls/)
    end
  end

  it 'says so instead of dividing by zero when there is nothing to read' do
    expect(described_class.report([])).to include('no tool results found')
  end
end
