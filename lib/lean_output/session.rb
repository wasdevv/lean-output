# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'

module LeanOutput
  # What the plugin remembers between hook invocations, in one file per session.
  #
  # A hook is a fresh process per tool call, so anything spanning calls — the
  # active level, what the model has already been shown, what has been saved so
  # far — has nowhere to live but disk. One file rather than three: it is read
  # and rewritten on every call, and three files would be three round trips to
  # say the same thing.
  #
  # Nothing here raises. A session that cannot be read is an empty one, and a
  # save that cannot be written is dropped — the worst case is that the ledger
  # forgets and a repeated output is sent twice, which is exactly the behaviour
  # before this file existed.
  class Session
    VERSION = 1
    # Entries are pruned to the most recent N. The window in Ledger already
    # decides what is too old to reference; this is only so the file cannot grow
    # without bound in a session that runs for hours.
    MAX_SEEN = 300

    attr_reader :id, :data

    def self.load(payload)
      id = identify(payload)
      new(id, read(path(id)))
    end

    def self.identify(payload)
      raw = payload['session_id'] || payload['sessionId']
      clean = raw.to_s.gsub(/[^A-Za-z0-9_-]/, '')[0, 64]
      return clean unless clean.empty?

      # No session id (an older host, or a direct caller) still gets isolation
      # per working directory, which is the next best proxy for "one agent".
      cwd = payload['cwd'].to_s
      cwd.empty? ? 'global' : "cwd-#{Digest::SHA256.hexdigest(cwd)[0, 16]}"
    end

    def self.dir
      ENV['LEAN_OUTPUT_STATE_DIR'] ||
        File.join(ENV['XDG_CACHE_HOME'] || File.join(Dir.home, '.cache'), 'lean-output')
    end

    def self.path(id)
      File.join(dir, "#{id}.json")
    end

    def self.read(file)
      parsed = JSON.parse(File.read(file))
      parsed.is_a?(Hash) && parsed['v'] == VERSION ? parsed : blank
    rescue StandardError
      blank
    end

    def self.blank
      { 'v' => VERSION, 'seq' => 0, 'bytes' => 0, 'seen' => {}, 'gain' => gain_blank }
    end

    def self.gain_blank
      { 'calls' => 0, 'before' => 0, 'after' => 0, 'hits' => 0, 'hit_bytes' => 0 }
    end

    def initialize(id, data)
      @id = id
      @data = data
    end

    def seq
      data['seq'].to_i
    end

    def bytes
      data['bytes'].to_i
    end

    # Every result the hook sees advances the clock, whether or not it was
    # rewritten. The ledger measures its window in these bytes, so a result that
    # passed through still has to count: it occupied the context all the same.
    def advance(size)
      data['seq'] = seq + 1
      data['bytes'] = bytes + size.to_i
    end

    # [seq, bytes-at-the-time, label, size] — positional to keep the file small,
    # since it is rewritten on every single tool call.
    def lookup(digest)
      entry = data['seen'][digest]
      return nil unless entry.is_a?(Array) && entry.size == 4

      { seq: entry[0], bytes: entry[1], label: entry[2], size: entry[3] }
    end

    def remember(digest, label, size)
      data['seen'][digest] = [seq, bytes, label, size]
      prune
    end

    def credit(before, after, hit: false)
      gain = data['gain'] ||= self.class.gain_blank
      gain['calls'] += 1
      gain['before'] += before
      gain['after'] += after
      return unless hit

      gain['hits'] += 1
      gain['hit_bytes'] += before - after
    end

    def gain
      data['gain'] || self.class.gain_blank
    end

    def save
      file = self.class.path(id)
      FileUtils.mkdir_p(File.dirname(file))
      temp = "#{file}.#{Process.pid}.tmp"
      File.write(temp, JSON.generate(data))
      File.rename(temp, file)
      true
    rescue StandardError
      false
    end

    def prune
      seen = data['seen']
      return if seen.size <= MAX_SEEN

      keep = seen.sort_by { |_, entry| -entry[0].to_i }.first(MAX_SEEN)
      data['seen'] = keep.to_h
    end
    private :prune
  end
end
