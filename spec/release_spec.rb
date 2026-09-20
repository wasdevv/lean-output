# frozen_string_literal: true

require 'spec_helper'
require 'json'

# This repo ships through two doors and neither one reads the other's version.
#
#   - as a Claude Code plugin, where the host installs by the version in
#     `.claude-plugin/plugin.json` and caches it in a directory named after it;
#   - as a gem, where the gemspec reads `LeanOutput::VERSION`.
#
# Bumping one and forgetting the other does not raise anywhere. It produces a
# plugin cache holding 1.7.0 whose library reports 1.6.0, and a `/lean` receipt
# that names a version nobody can match to a commit — which is the same failure
# every measurement in this repo has already had once, an answer that was right
# when it was written and silently stopped being.
RSpec.describe 'the two doors this ships through' do
  let(:manifest) { JSON.parse(File.read(File.expand_path('../.claude-plugin/plugin.json', __dir__))) }

  it 'declares one version to the plugin host and to the gem' do
    expect(manifest['version']).to eq(LeanOutput::VERSION)
  end

  # The hook is launched by a line in hooks.json, not by anything Ruby can
  # check, so the one thing a spec can hold is that the line still names the
  # flag that took the hook from 71ms to 23ms per tool call.
  it 'launches the hook without RubyGems' do
    hooks = JSON.parse(File.read(File.expand_path('../hooks/hooks.json', __dir__)))
    commands = hooks.fetch('hooks').values.flatten
                    .flat_map { |matcher| matcher['hooks'] }.map { |hook| hook['command'] }

    expect(commands).to all(include('--disable=gems'))
    expect(commands).not_to be_empty
  end

  # The other thing only this file can hold. `Session#floor` is what stops the
  # ledger promising that bytes a compaction took away are still in the window,
  # and nothing sets it except the host firing this event — drop the line and
  # every rung goes back to guessing, with no test anywhere going red.
  it 'asks the host to tell it when the window is cut' do
    hooks = JSON.parse(File.read(File.expand_path('../hooks/hooks.json', __dir__)))

    expect(hooks.fetch('hooks')).to include('PreCompact')
  end

  # The second layer is a file the host imports by path, and a rename is the one
  # breakage nothing else here would notice: the command hooks would keep
  # working, the suite would stay green, and the compaction pass would simply
  # never load. The manifest is also the only place the requirement is written
  # down, so the module and the file it names are checked together.
  it 'ships the hooks module it names' do
    root = File.expand_path('..', __dir__)
    hooks = JSON.parse(File.read(File.join(root, 'hooks/hooks.json')))
    modules = hooks.fetch('modules')

    expect(modules).not_to be_empty
    modules.each { |path| expect(File.file?(File.join(root, 'hooks', path))).to be(true) }
  end

  # A default gem resolves without RubyGems; a real one does not. The hook has a
  # rescue for that, but the cheap check is that nothing new crept into the load
  # path the hook walks.
  it 'requires nothing at load time that RubyGems has to find' do
    # RUBYOPT is cleared because `bundle exec` puts `-rbundler/setup` in it, and
    # bundler loads fileutils — the test environment would answer for the hook,
    # which launches with no such thing.
    loaded = `env RUBYOPT= ruby --disable=gems -r./lib/lean_output -e 'puts $LOADED_FEATURES' 2>&1`

    expect(loaded).to include('lean_output.rb')
    expect(loaded).not_to include('tmpdir.rb')
    expect(loaded).not_to include('fileutils.rb')
  end
end
