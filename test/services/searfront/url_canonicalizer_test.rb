require "test_helper"

class Searfront::UrlCanonicalizerTest < ActiveSupport::TestCase
  test "removes fragment tracking params and default port" do
    assert_equal(
      "https://example.org/path?a=1&b=2",
      Searfront::UrlCanonicalizer.call("https://EXAMPLE.org:443/path?utm_source=x&b=2&a=1#section")
    )
  end

  test "rejects unsafe schemes" do
    assert_nil Searfront::UrlCanonicalizer.call("javascript:alert(1)")
  end
end
