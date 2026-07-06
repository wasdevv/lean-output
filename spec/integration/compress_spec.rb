require "json"
require "open3"

RSpec.describe "bin/compress" do
  BIN = File.expand_path("../../bin/compress", __dir__)

  def run_hook(payload, env = {})
    stdout, stderr, status = Open3.capture3(env, "ruby", BIN, stdin_data: JSON.generate(payload))
    [stdout, stderr, status]
  end

  def payload_for(command, output)
    {
      "tool_name" => "Bash",
      "tool_input" => { "command" => command },
      "tool_response" => { "stdout" => output, "stderr" => "" }
    }
  end

  it "compresses a failing rspec run and reports the savings" do
    original = fixture("rspec_failures.txt")
    stdout, _, status = run_hook(payload_for("bundle exec rspec", original))

    expect(status.exitstatus).to eq(0)
    result = JSON.parse(stdout)
    updated = result.dig("hookSpecificOutput", "updatedToolOutput")
    expect(result.dig("hookSpecificOutput", "hookEventName")).to eq("PostToolUse")
    expect(updated).to include("106 examples, 3 failures")
    expect(updated).to include("./spec/lean_output_fixture_tmp_spec.rb:4")
    expect(updated).to include("[lean-output]")
    expect(updated.bytesize).to be < original.bytesize * 0.35
  end

  it "compresses failed tool calls (PostToolUseFailure payload with error field)" do
    payload = {
      "tool_name" => "Bash",
      "hook_event_name" => "PostToolUseFailure",
      "tool_input" => { "command" => "bundle exec rspec" },
      "error" => "Exit code 1\n\n" + fixture("rspec_failures.txt")
    }
    stdout, _, status = run_hook(payload)

    expect(status.exitstatus).to eq(0)
    result = JSON.parse(stdout)
    expect(result.dig("hookSpecificOutput", "hookEventName")).to eq("PostToolUseFailure")
    updated = result.dig("hookSpecificOutput", "updatedToolOutput")
    expect(updated).to start_with("Exit code 1\n")
    expect(updated).to include("3 failures")
  end

  it "compresses a rubocop run" do
    stdout, _, status = run_hook(payload_for("bin/rubocop app/", fixture("rubocop_offenses.txt")))

    expect(status.exitstatus).to eq(0)
    updated = JSON.parse(stdout).dig("hookSpecificOutput", "updatedToolOutput")
    expect(updated).to include("13 offenses detected")
  end

  it "accepts tool_response as a plain string" do
    stdout, _, status = run_hook(payload_for("rspec", fixture("rspec_failures.txt")).merge(
      "tool_response" => fixture("rspec_failures.txt")
    ))

    expect(status.exitstatus).to eq(0)
    expect(JSON.parse(stdout).dig("hookSpecificOutput", "updatedToolOutput")).to include("3 failures")
  end

  describe "passthrough (no stdout, exit 0)" do
    it "stays silent for small outputs" do
      stdout, _, status = run_hook(payload_for("rspec", "3 examples, 0 failures\n"))
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it "stays silent for unrelated commands" do
      stdout, _, status = run_hook(payload_for("ls -la", fixture("rspec_failures.txt")))
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it "stays silent for non-Bash tools" do
      stdout, _, status = run_hook(payload_for("rspec", fixture("rspec_failures.txt")).merge("tool_name" => "Read"))
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it "stays silent on invalid JSON stdin" do
      stdout, _, status = Open3.capture3("ruby", BIN, stdin_data: "not json at all {")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end

    it "respects the LEAN_OUTPUT_DISABLE kill-switch" do
      stdout, _, status = run_hook(
        payload_for("rspec", fixture("rspec_failures.txt")),
        { "LEAN_OUTPUT_DISABLE" => "1" }
      )
      expect(status.exitstatus).to eq(0)
      expect(stdout).to be_empty
    end
  end
end
