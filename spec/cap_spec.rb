# frozen_string_literal: true

require 'spec_helper'

# The PreToolUse envelope is copied from the host's own schema, read out of the
# binary rather than inferred from what this code emits:
#
#   { hookEventName: "PreToolUse", permissionDecision: enum?,
#     permissionDecisionReason: string?, updatedInput: record?,
#     additionalContext: string? }
#
# `updatedInput` is honoured on its own only when no permissionDecision is set;
# with one, the host takes it solely for "allow" and "ask". That is why nothing
# here returns a decision — see the note in Cap.
RSpec.describe LeanOutput::Cap do
  def cap(command, tool: 'Bash')
    LeanOutput::Runner.call(
      'hook_event_name' => 'PreToolUse', 'session_id' => 'cap-spec', 'cwd' => Dir.pwd,
      'tool_name' => tool, 'tool_input' => { 'command' => command }
    )
  end

  def capped_command(command)
    cap(command)&.dig('hookSpecificOutput', 'updatedInput', 'command')
  end

  it 'appends a ceiling to an unbounded listing' do
    expect(capped_command('grep -rn "def " app/')).to eq('grep -rn "def " app/ | head -n 200')
  end

  it 'names the event and asks for no permission decision' do
    output = cap('find . -name "*.rb"').fetch('hookSpecificOutput')

    expect(output['hookEventName']).to eq('PreToolUse')
    expect(output).not_to have_key('permissionDecision')
    expect(output['additionalContext']).to include('200 lines')
  end

  it 'keeps every other key of the tool input it was given' do
    payload = { 'hook_event_name' => 'PreToolUse', 'session_id' => 'cap-spec', 'cwd' => Dir.pwd,
                'tool_name' => 'Bash',
                'tool_input' => { 'command' => 'ls -R', 'description' => 'list', 'timeout' => 5000 } }
    updated = LeanOutput::Runner.call(payload).dig('hookSpecificOutput', 'updatedInput')

    expect(updated['description']).to eq('list')
    expect(updated['timeout']).to eq(5000)
  end

  # Over-refusing costs a rewrite that was optional; misreading a quote corrupts
  # a command about to run. Every one of these goes through untouched.
  it 'refuses anything carrying a shell metacharacter, quoted or not' do
    ['grep -rn "foo|bar" app/', 'grep -rn x app/ | head -5', 'cat a.txt > b.txt',
     'ls && echo done', 'cat $(ls)', 'grep -rn x `pwd`', "ls;\nrm -rf /"].each do |command|
      expect(capped_command(command)).to be_nil, "expected #{command.inspect} left alone"
    end
  end

  it 'leaves a command that already carries its own ceiling alone' do
    expect(capped_command('grep -rn -m 5 x app/')).to be_nil
    expect(capped_command('grep -rn --max-count=5 x app/')).to be_nil
    expect(capped_command('head -n 20 big.log')).to be_nil
    expect(capped_command('tail -f log/development.log')).to be_nil
  end

  it 'caps nothing outside the roster, however long its output' do
    expect(capped_command('bundle exec rspec')).to be_nil
    expect(capped_command('sed -n 1,9999p big.log')).to be_nil
    expect(capped_command('rm -rf tmp/')).to be_nil
  end

  it 'reaches a command reached by its path' do
    expect(capped_command('/usr/bin/grep -rn x app/')).to eq('/usr/bin/grep -rn x app/ | head -n 200')
  end

  it 'is not a Bash-only event, so it ignores every other tool' do
    expect(cap('grep -rn x app/', tool: 'Read')).to be_nil
  end

  # Capping discards bytes, so it is not lossless, so `safe` must not do it.
  it 'stands down at the levels that promised not to discard anything' do
    { 'safe' => nil, 'off' => nil, 'full' => 'grep -rn x app/ | head -n 200' }.each do |level, expected|
      ENV['LEAN_OUTPUT_MODE'] = level
      expect(capped_command('grep -rn x app/')).to eq(expected), "level #{level}"
    ensure
      ENV.delete('LEAN_OUTPUT_MODE')
    end
  end
end
