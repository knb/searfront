require "test_helper"
require "tmpdir"
require Rails.root.join("script/rotate_searxng_engines")

class RotateSearxngEnginesTest < ActiveSupport::TestCase
  test "cycles rotation groups and preserves existing settings" do
    Dir.mktmpdir do |dir|
      settings_path = File.join(dir, "settings.yml")
      state_path = File.join(dir, "rotation.json")
      File.write(settings_path, <<~YAML)
        use_default_settings: true
        server:
          secret_key: keep-me
      YAML

      first = SearxngEngineRotation.call(
        settings_path: settings_path,
        state_path: state_path,
        rotations: "google,duckduckgo;bing,brave"
      )
      second = SearxngEngineRotation.call(
        settings_path: settings_path,
        state_path: state_path,
        rotations: "google,duckduckgo;bing,brave"
      )

      settings = YAML.safe_load_file(settings_path)
      assert_equal %w[google duckduckgo], first
      assert_equal %w[bing brave], second
      assert_equal %w[bing brave], settings.dig("use_default_settings", "engines", "keep_only")
      assert_equal %w[html json], settings.dig("search", "formats")
      assert_equal "keep-me", settings.dig("server", "secret_key")
    end
  end

  test "rejects an empty rotation configuration" do
    assert_raises(ArgumentError) { SearxngEngineRotation.parse_rotations(" ; , ") }
  end

  test "rejects engine names with YAML control characters" do
    assert_raises(ArgumentError) { SearxngEngineRotation.parse_rotations("google;bad: engine") }
  end
end
