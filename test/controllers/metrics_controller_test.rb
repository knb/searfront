require "test_helper"

class MetricsControllerTest < ActionDispatch::IntegrationTest
  test "returns prometheus compatible metrics" do
    with_env("SEARFRONT_API_TOKENS" => "test:test-secret:user") do
      Searfront::Metrics.reset!
      Searfront::Metrics.increment("searfront_requests_total", status: 200, path: "/healthz")
      Searfront::Metrics.observe("searfront_request_duration_seconds", 0.012, path: "/healthz")

      get "/metrics", headers: auth_headers
    end

    assert_response :success
    assert_includes response.body, "# TYPE searfront_requests_total counter"
    assert_includes response.body, "searfront_requests_total{path=\"/healthz\",status=\"200\"} 1"
    assert_includes response.body, "searfront_request_duration_seconds_count{path=\"/healthz\"} 1"
  end

  private

  def auth_headers
    { "Authorization" => "Bearer test-secret" }
  end
end
