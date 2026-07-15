require "test_helper"

module V1
  class SearchRequestsControllerTest < ActionDispatch::IntegrationTest
    class FakeRedis
      def initialize(store)
        @store = store
      end

      def get(key)
        store[key]
      end

      def set(key, value, ex: nil, nx: false, px: nil)
        return false if nx && store.key?(key)

        store[key] = value
        true
      end

      def close; end

      private

      attr_reader :store
    end

    test "returns pending request status" do
      with_status_env do
        Searfront::RequestStatus.new.pending("request-1", "cache-key-1")

        get "/v1/search_requests/request-1", headers: auth_headers
      end

      assert_response :accepted
      body = response.parsed_body
      assert_equal "pending", body["status"]
      assert_equal "request-1", body["request_id"]
      assert_equal 3, body["poll_after_seconds"]
    end

    test "returns completed request payload" do
      with_status_env do |redis|
        cache_key = "searfront:cache:v1:result:test"
        redis.set(cache_key, completed_cache_payload)
        Searfront::RequestStatus.new.complete("request-2", cache_key)

        get "/v1/search_requests/request-2", headers: auth_headers
      end

      assert_response :success
      assert_equal "completed", response.parsed_body["status"]
      assert_equal "browser result", response.parsed_body.dig("results", 0, "title")
    end

    test "returns not found for unknown request id" do
      with_status_env do
        get "/v1/search_requests/missing", headers: auth_headers
      end

      assert_response :not_found
      assert_equal "not_found", response.parsed_body.dig("error", "code")
    end

    private

    def with_status_env
      store = {}
      redis = FakeRedis.new(store)

      with_env(
        "SEARFRONT_API_TOKENS" => "test:test-secret:user",
        "CACHE_REDIS_URL" => "redis://cache.example:6379/0",
        "STATE_REDIS_URL" => "redis://state.example:6379/0"
      ) do
        with_redis_stub(redis) { yield(redis) }
      end
    end

    def with_redis_stub(redis)
      original_new = Redis.method(:new)
      Redis.define_singleton_method(:new) { |**| redis }
      yield
    ensure
      Redis.define_singleton_method(:new, original_new)
    end

    def auth_headers
      { "Authorization" => "Bearer test-secret" }
    end

    def completed_cache_payload
      JSON.generate(
        {
          "request_id" => "request-2",
          "status" => "completed",
          "query" => "browser query",
          "normalized_query" => "browser query",
          "cache" => {
            "status" => "fresh",
            "age_seconds" => 0,
            "generated_at" => Time.current.utc.iso8601
          },
          "sources" => [ "browser" ],
          "results" => [
            {
              "title" => "browser result",
              "url" => "https://example.org/browser",
              "canonical_url" => "https://example.org/browser",
              "snippet" => "browser snippet",
              "engines" => [ "google" ],
              "source" => "browser",
              "rank" => 1,
              "published_at" => nil,
              "metadata" => {}
            }
          ],
          "warnings" => [],
          "timing_ms" => {},
          "fresh_until" => 30.minutes.from_now.utc.iso8601
        }
      )
    end
  end
end
