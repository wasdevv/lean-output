# frozen_string_literal: true

require 'json'
require 'open3'

RSpec.describe 'bin/compress' do
  BIN = File.expand_path('../../bin/compress', __dir__)

  def run_hook(payload, env = {})
    stdout, stderr, status = Open3.capture3(env, 'ruby', BIN, stdin_data: JSON.generate(payload))
    [stdout, stderr, status]
  end

  def payload_for(command, output)
    {
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => command },
      'tool_response' => { 'stdout' => output, 'stderr' => '' }
    }
  end

  # A Read arrives as a structured result, not a stdout string — the ledger has
  # to reach through `file.content` to see the bytes it is deduplicating.
  def read_payload(path, content)
    {
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => path },
      'tool_response' => { 'type' => 'text', 'file' => { 'filePath' => path, 'content' => content } }
    }
  end

  it 'compresses a failing rspec run and reports the savings' do
    original = fixture('rspec_failures.txt')
    stdout, _, status = run_hook(payload_for('bundle exec rspec', original))

    expect(status.exitstatus).to eq(0)
    result = JSON.parse(stdout)
    updated = updated_text(result)
    expect(result.dig('hookSpecificOutput', 'hookEventName')).to eq('PostToolUse')
    expect(updated).to include('106 examples, 3 failures')
    expect(updated).to include('./spec/lean_output_fixture_tmp_spec.rb:4')
    expect(updated).to include('[lean-output]')
    expect(updated.bytesize).to be < original.bytesize * 0.35
  end

  it 'compresses failed tool calls (PostToolUseFailure payload with error field)' do
    payload = {
      'tool_name' => 'Bash',
      'hook_event_name' => 'PostToolUseFailure',
      'tool_input' => { 'command' => 'bundle exec rspec' },
      'error' => "Exit code 1\n\n#{fixture('rspec_failures.txt')}"
    }
    stdout, _, status = run_hook(payload)

    expect(status.exitstatus).to eq(0)
    result = JSON.parse(stdout)
    expect(result.dig('hookSpecificOutput', 'hookEventName')).to eq('PostToolUseFailure')
    updated = updated_text(result)
    expect(updated).to start_with("Exit code 1\n")
    expect(updated).to include('3 failures')
  end

  it 'compresses a rubocop run' do
    stdout, _, status = run_hook(payload_for('bin/rubocop app/', fixture('rubocop_offenses.txt')))

    expect(status.exitstatus).to eq(0)
    updated = updated_text(JSON.parse(stdout))
    expect(updated).to include('13 offenses detected')
  end

  it 'accepts tool_response as a plain string' do
    stdout, _, status = run_hook(payload_for('rspec', fixture('rspec_failures.txt')).merge(
                                   'tool_response' => fixture('rspec_failures.txt')
                                 ))

    expect(status.exitstatus).to eq(0)
    expect(updated_text(JSON.parse(stdout))).to include('3 failures')
  end

  describe 'MCP tool results' do
    def mcp_payload(tool, output)
      {
        'tool_name' => tool,
        'tool_input' => { 'query' => 'select * from information_schema.columns' },
        'tool_response' => [{ 'type' => 'text', 'text' => output }]
      }
    end

    it 'compresses a row set returned as content blocks' do
      original = fixture('mcp_query_rows.json')
      stdout, _, status = run_hook(mcp_payload('mcp__insforge__query', original))

      expect(status.exitstatus).to eq(0)
      updated = updated_text(JSON.parse(stdout))
      expect(updated).to include('JSON rows: 40 rows, 7 columns')
      expect(updated.bytesize).to be < original.bytesize * 0.45
    end

    it 'keeps every value the query returned' do
      original = fixture('mcp_query_rows.json')
      stdout, = run_hook(mcp_payload('mcp__insforge__query', original))
      updated = updated_text(JSON.parse(stdout))

      JSON.parse(original).each do |row|
        row.each_value { |value| expect(updated).to include(value.nil? ? 'null' : value.to_s) }
      end
    end

    it 'stays silent for a result a table cannot represent' do
      stdout, _, status = run_hook(mcp_payload('mcp__insforge__query', fixture('mcp_query_nested.json')))
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it 'stays silent below the byte gate' do
      stdout, _, status = run_hook(mcp_payload('mcp__insforge__query', JSON.generate([{ 'a' => 1 }] * 6)))
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end
  end

  describe 'the floor a rewrite has to clear' do
    it 'swaps in a lossless rewrite saving less than a lossy one would need' do
      original = fixture('grep_hits.txt')
      stdout, _, status = run_hook(payload_for('grep -rn "plain" lib/', original))

      expect(status.exitstatus).to eq(0)
      updated = updated_text(JSON.parse(stdout))
      expect(updated).to include("lib/lean_output.rb\n")

      # Between the two floors: at this ratio a lossy compressor stays put.
      policy = LeanOutput::Mode::POLICY.fetch('full')
      saving = 1.0 - updated.bytesize.to_f / original.bytesize
      expect(saving).to be > (1 - policy.fetch(:lossless_ratio))
      expect(saving).to be < (1 - policy.fetch(:ratio))
    end
  end

  describe 'passthrough (no stdout, exit 0)' do
    it 'stays silent for small outputs' do
      stdout, _, status = run_hook(payload_for('rspec', "3 examples, 0 failures\n"))
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it 'stays silent for unrelated commands' do
      stdout, _, status = run_hook(payload_for('ls -la', fixture('rspec_failures.txt')))
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it 'stays silent for a tool no compressor claims' do
      stdout, _, status = run_hook(payload_for('rspec', fixture('rspec_failures.txt')).merge('tool_name' => 'Glob'))
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it 'stays silent for a Read the session has not seen' do
      stdout, _, status = run_hook(read_payload('lib/lean_output.rb', fixture('rspec_failures.txt')))
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it 'stays silent on invalid JSON stdin' do
      stdout, _, status = Open3.capture3('ruby', BIN, stdin_data: 'not json at all {')
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it 'respects the LEAN_OUTPUT_DISABLE kill-switch' do
      stdout, _, status = run_hook(
        payload_for('rspec', fixture('rspec_failures.txt')),
        { 'LEAN_OUTPUT_DISABLE' => '1' }
      )
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end
  end

  describe 'the ledger' do
    it 'points a repeated Read back at the first one instead of resending it' do
      payload = read_payload('lib/lean_output.rb', fixture('rspec_failures.txt'))
      run_hook(payload)
      stdout, _, status = run_hook(payload)

      expect(status.exitstatus).to eq(0)
      updated = updated_text(JSON.parse(stdout))
      expect(updated).to include('byte-identical to Read lib/lean_output.rb')
      expect(updated).to include('1 tool call back')
    end

    it 'resends a Read whose content changed by a single byte' do
      run_hook(read_payload('lib/lean_output.rb', fixture('rspec_failures.txt')))
      stdout, _, status = run_hook(read_payload('lib/lean_output.rb', "#{fixture('rspec_failures.txt')} "))

      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it 'keeps enough of the head to recognise what the pointer points at' do
      payload = read_payload('lib/lean_output.rb', fixture('rspec_failures.txt'))
      run_hook(payload)
      stdout, = run_hook(payload)

      updated = updated_text(JSON.parse(stdout))
      expect(updated.lines.size).to eq(3)
      expect(updated).to include(fixture('rspec_failures.txt').lines.first.chomp[0, 40])
    end

    # The window is measured in the tool-output bytes that went by since, so it
    # takes a call in between to push the first occurrence out of reach.
    it 'forgets a result that fell out of the recency window' do
      payload = read_payload('lib/lean_output.rb', fixture('rspec_failures.txt'))
      run_hook(payload)
      run_hook(read_payload('lib/lean_output/text.rb', fixture('rubocop_offenses.txt')))
      stdout, _, status = run_hook(payload, { 'LEAN_OUTPUT_WINDOW' => '100' })

      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it 'still points back when the window is wide enough to reach' do
      payload = read_payload('lib/lean_output.rb', fixture('rspec_failures.txt'))
      run_hook(payload)
      run_hook(read_payload('lib/lean_output/text.rb', fixture('rubocop_offenses.txt')))
      stdout, = run_hook(payload)

      updated = updated_text(JSON.parse(stdout))
      expect(updated).to include('2 tool calls back')
    end
  end
end
