#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "pathname"
require "psych"
require "tempfile"
require "time"

module SearxngEngineRotation
  module_function

  DEFAULT_ROTATIONS = "google,duckduckgo;bing,brave;qwant,mojeek"

  def call(settings_path:, state_path:, rotations: DEFAULT_ROTATIONS)
    groups = parse_rotations(rotations)
    state = read_state(state_path)
    index = state.fetch("next_index", 0) % groups.length
    engines = groups.fetch(index)

    settings = read_settings(settings_path)
    defaults = settings["use_default_settings"]
    defaults = {} unless defaults.is_a?(Hash)
    defaults["engines"] = {} unless defaults["engines"].is_a?(Hash)
    defaults["engines"]["keep_only"] = engines
    settings["use_default_settings"] = defaults

    search = settings["search"]
    search = {} unless search.is_a?(Hash)
    search["formats"] = (Array(search["formats"]) | %w[html json])
    settings["search"] = search

    atomic_write(settings_path, Psych.safe_dump(settings, aliases: false))
    atomic_write(
      state_path,
      JSON.pretty_generate(
        "active_index" => index,
        "active_engines" => engines,
        "next_index" => (index + 1) % groups.length,
        "rotated_at" => Time.now.utc.iso8601
      ) + "\n"
    )

    engines
  end

  def parse_rotations(value)
    groups = value.to_s.split(";").map do |group|
      group.split(",").map(&:strip).reject(&:empty?).uniq
    end.reject(&:empty?)
    raise ArgumentError, "at least one engine rotation group is required" if groups.empty?

    invalid = groups.flatten.reject { |name| name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9 ._+-]*\z/) }
    raise ArgumentError, "invalid engine names: #{invalid.join(', ')}" if invalid.any?

    groups
  end

  def read_settings(path)
    payload = Psych.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: false)
    raise ArgumentError, "settings must contain a YAML mapping: #{path}" unless payload.is_a?(Hash)

    payload
  rescue Errno::ENOENT
    raise ArgumentError, "settings file not found: #{path}"
  end

  def read_state(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end

  def atomic_write(path, content)
    destination = Pathname(path)
    FileUtils.mkdir_p(destination.dirname)
    Tempfile.create([ destination.basename.to_s, ".tmp" ], destination.dirname.to_s) do |file|
      file.write(content)
      file.flush
      file.fsync
      FileUtils.chmod(File.stat(destination).mode, file.path) if destination.exist?
      File.rename(file.path, destination)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    rotations: ENV.fetch("SEARXNG_ENGINE_ROTATIONS", SearxngEngineRotation::DEFAULT_ROTATIONS)
  }
  OptionParser.new do |parser|
    parser.banner = "Usage: rotate_searxng_engines.rb --settings PATH --state PATH"
    parser.on("--settings PATH") { |value| options[:settings_path] = value }
    parser.on("--state PATH") { |value| options[:state_path] = value }
    parser.on("--rotations GROUPS") { |value| options[:rotations] = value }
  end.parse!

  abort("--settings is required") unless options[:settings_path]
  abort("--state is required") unless options[:state_path]

  active = SearxngEngineRotation.call(**options)
  puts "Activated SearXNG engines: #{active.join(', ')}"
end
