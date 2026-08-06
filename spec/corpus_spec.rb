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

  it 'says so instead of dividing by zero when there is nothing to read' do
    expect(described_class.report([])).to include('no tool results found')
  end
end
