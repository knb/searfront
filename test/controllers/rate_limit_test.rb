require "test_helper"

class RateLimitTest < ActionDispatch::IntegrationTest
  test "throttles excessive requests by bearer token" do
    Rack::Attack.cache.store.clear

    with_env(
      "SEARFRONT_API_TOKENS" => "test:test-secret:user",
      "SEARFRONT_RATE_LIMIT_PER_MINUTE" => "1"
    ) do
      get "/healthz", headers: auth_headers
      get "/healthz", headers: auth_headers
    end

    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body.dig("error", "code")
  ensure
    Rack::Attack.cache.store.clear
  end

  private

  def auth_headers
    { "Authorization" => "Bearer test-secret" }
  end
end
