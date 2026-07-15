require "test_helper"

class ReadinessControllerTest < ActionDispatch::IntegrationTest
  class FakeRedis
    def ping
      "PONG"
    end

    def close; end
  end

  test "rejects readiness requests without bearer token" do
    get "/readyz"

    assert_response :unauthorized
    body = response.parsed_body
    assert_equal "unauthorized", body.dig("error", "code")
    assert_equal false, body["retryable"]
    assert body["request_id"].present?
  end

  test "returns ready when dependencies respond" do
    with_phase_one_env do
      stub_request(:get, "http://searxng:8080/").to_return(status: 200, body: "ok")

      with_redis_stub do
        get "/readyz", headers: auth_headers
      end
    end

    assert_response :success
    body = response.parsed_body
    assert_equal "ready", body["status"]
    assert_equal "ok", body.dig("checks", "cache_redis", "status")
    assert_equal "ok", body.dig("checks", "state_redis", "status")
    assert_equal "ok", body.dig("checks", "sidekiq_redis", "status")
    assert_equal "ok", body.dig("checks", "searxng", "status")
  end

  test "returns not ready when dependencies are missing" do
    with_env(
      "SEARFRONT_API_TOKENS" => "test:test-secret:user",
      "CACHE_REDIS_URL" => nil,
      "STATE_REDIS_URL" => nil,
      "SIDEKIQ_REDIS_URL" => nil,
      "SEARXNG_BASE_URL" => nil
    ) do
      get "/readyz", headers: auth_headers
    end

    assert_response :service_unavailable
    body = response.parsed_body
    assert_equal "not_ready", body["status"]
    assert_equal "error", body.dig("checks", "cache_redis", "status")
    assert_equal "error", body.dig("checks", "searxng", "status")
  end

  test "request log omits raw query text" do
    log_output = StringIO.new
    logger = ActiveSupport::Logger.new(log_output)

    with_phase_one_env do
      stub_request(:get, "http://searxng:8080/").to_return(status: 200, body: "ok")

      with_logger_stub(logger) do
        with_redis_stub do
          get "/readyz", params: { q: "secret search text" }, headers: auth_headers
        end
      end
    end

    assert_response :success
    assert_includes log_output.string, "query_digest"
    assert_includes log_output.string, "query_length"
    assert_not_includes log_output.string, "secret search text"
  end

  private

  def with_phase_one_env(&)
    with_env(
      "SEARFRONT_API_TOKENS" => "test:test-secret:user",
      "CACHE_REDIS_URL" => "redis://cache.example:6379/0",
      "STATE_REDIS_URL" => "redis://state.example:6379/0",
      "SIDEKIQ_REDIS_URL" => "redis://sidekiq.example:6379/0",
      "SEARXNG_BASE_URL" => "http://searxng:8080/"
    ) do
      yield
    end
  end

  def auth_headers
    { "Authorization" => "Bearer test-secret" }
  end

  def with_redis_stub
    original_new = Redis.method(:new)
    Redis.define_singleton_method(:new) { |**| FakeRedis.new }
    yield
  ensure
    Redis.define_singleton_method(:new, original_new)
  end

  def with_logger_stub(logger)
    original_logger = Rails.method(:logger)
    Rails.define_singleton_method(:logger) { logger }
    yield
  ensure
    Rails.define_singleton_method(:logger, original_logger)
  end
end
