require "test_helper"

module V1
  class SearchesControllerTest < ActionDispatch::IntegrationTest
    class FakeRedis
      attr_reader :sets

      def initialize(store)
        @store = store
        @sets = []
      end

      def get(key)
        store[key]
      end

      def set(key, value, ex: nil, nx: false, px: nil)
        return false if nx && store.key?(key)

        store[key] = value
        sets << { key: key, value: value, ex: ex, nx: nx, px: px }
        true
      end

      def del(key)
        store.delete(key) ? 1 : 0
      end

      def incr(key)
        store[key] = store.fetch(key, "0").to_i + 1
      end

      def expire(_key, _seconds)
        true
      end

      def eval(_script, keys:, argv:)
        return 0 unless store[keys.first] == argv.first

        store.delete(keys.first)
        1
      end

      def ping
        "PONG"
      end

      def close; end

      private

      attr_reader :store
    end

    test "returns search results from SearXNG and stores cache" do
      with_search_env do |redis|
        stub_searxng

        get "/v1/search", params: { q: " llama.cpp　Vulkan ", limit: 3 }, headers: auth_headers

        assert_response :success
        body = response.parsed_body
        assert_equal "completed", body["status"]
        assert_equal "llama.cpp Vulkan", body["normalized_query"]
        assert_equal "fresh", body.dig("cache", "status")
        assert_equal [ "searxng" ], body["sources"]
        assert_equal 3, body["results"].length
        assert redis.sets.any? { |set| set[:key].start_with?("searfront:cache:v1:result:") }
      end
    end

    test "returns fresh cache without calling SearXNG" do
      with_search_env do |redis|
        request = Searfront::SearchParams.build(ActionController::Parameters.new(q: "cache hit"))
        key = Searfront::CacheKey.for(request)
        redis.set(key, cached_payload(request, status: "fresh", fresh_until: 30.minutes.from_now))

        get "/v1/search", params: { q: "cache hit" }, headers: auth_headers

        assert_response :success
        body = response.parsed_body
        assert_equal "fresh", body.dig("cache", "status")
        assert_equal "cached result", body.dig("results", 0, "title")
        assert_not_requested :get, "http://searxng:8080/"
      end
    end

    test "returns stale cache when SearXNG has insufficient results" do
      with_search_env do |redis|
        request = Searfront::SearchParams.build(ActionController::Parameters.new(q: "stale fallback"))
        key = Searfront::CacheKey.for(request)
        redis.set(key, cached_payload(request, status: "fresh", fresh_until: 5.minutes.ago))
        stub_searxng(results: [ searxng_result(1) ])

        get "/v1/search", params: { q: "stale fallback" }, headers: auth_headers

        assert_response :success
        body = response.parsed_body
        assert_equal "stale", body.dig("cache", "status")
        assert_includes body["warnings"], "stale_result"
        assert_includes body["warnings"], "searxng_result_insufficient"
      end
    end

    test "queues browser fallback when no stale result is available" do
      with_search_env do
        stub_searxng(results: [ searxng_result(1) ])

        assert_enqueued_with(job: BrowserSearchJob, queue: "browser_search") do
          get "/v1/search", params: { q: "needs browser fallback" }, headers: auth_headers
        end

        assert_response :accepted
        body = response.parsed_body
        assert_equal "pending", body["status"]
        assert_includes body["warnings"], "browser_fallback_queued"
        assert_includes body["warnings"], "searxng_result_insufficient"
      end
    end

    test "uses exa before browser fallback when searxng is insufficient" do
      with_search_env({ "EXA_API_KEY" => "exa-key" }) do
        stub_searxng(results: [ searxng_result(1) ])
        stub_exa(results: [ exa_result(1), exa_result(2) ])

        assert_no_enqueued_jobs only: BrowserSearchJob do
          get "/v1/search", params: { q: "needs exa fallback" }, headers: auth_headers
        end

        assert_response :success
        body = response.parsed_body
        assert_equal "completed", body["status"]
        assert_equal [ "searxng", "exa" ], body["sources"]
        assert_equal 3, body["results"].length
        assert_requested :post, "https://api.exa.ai/search"
      end
    end

    test "does not call exa after daily limit is exhausted" do
      with_search_env({ "EXA_API_KEY" => "exa-key", "EXA_DAILY_LIMIT" => "0" }) do
        stub_searxng(results: [ searxng_result(1) ])

        assert_enqueued_with(job: BrowserSearchJob, queue: "browser_search") do
          get "/v1/search", params: { q: "exa quota exhausted" }, headers: auth_headers
        end

        assert_response :accepted
        assert_not_requested :post, "https://api.exa.ai/search"
      end
    end

    test "does not queue browser fallback when browser engine is suspended" do
      with_search_env do
        Searfront::EngineState.new.suspend("google", reason: "captcha", duration: 1.hour)
        stub_searxng(results: [ searxng_result(1) ])

        assert_no_enqueued_jobs only: BrowserSearchJob do
          get "/v1/search", params: { q: "suspended browser fallback" }, headers: auth_headers
        end

        assert_response :bad_gateway
        assert_equal "upstream_error", response.parsed_body.dig("error", "code")
      end
    end

    test "rejects invalid request" do
      with_search_env do
        get "/v1/search", params: { q: "" }, headers: auth_headers
      end

      assert_response :bad_request
      assert_equal "invalid_request", response.parsed_body.dig("error", "code")
    end

    test "requires authentication" do
      get "/v1/search", params: { q: "llama.cpp" }

      assert_response :unauthorized
    end

    test "requires admin for refresh" do
      with_search_env do
        get "/v1/search", params: { q: "llama.cpp", refresh: true }, headers: auth_headers
      end

      assert_response :forbidden
    end

    test "requires admin for browser mode" do
      with_search_env do
        get "/v1/search", params: { q: "llama.cpp", mode: "browser" }, headers: auth_headers
      end

      assert_response :forbidden
    end

    test "queues browser search directly in browser mode" do
      with_search_env(api_tokens: "admin:admin-secret:admin") do
        assert_enqueued_with(job: BrowserSearchJob, queue: "browser_search") do
          get "/v1/search", params: { q: "browser only", mode: "browser" }, headers: admin_headers
        end

        assert_response :accepted
        body = response.parsed_body
        assert_equal "pending", body["status"]
        assert_includes body["warnings"], "browser_mode_requested"
        assert_not_requested :get, "http://searxng:8080/"
      end
    end

    private

    def with_search_env(extra_env = {}, api_tokens: "test:test-secret:user")
      store = {}
      redis = FakeRedis.new(store)

      with_env({
        "SEARFRONT_API_TOKENS" => api_tokens,
        "CACHE_REDIS_URL" => "redis://cache.example:6379/0",
        "STATE_REDIS_URL" => "redis://state.example:6379/0",
        "SIDEKIQ_REDIS_URL" => "redis://sidekiq.example:6379/0",
        "SEARXNG_BASE_URL" => "http://searxng:8080/",
        "MINIMUM_RESULTS" => "3"
      }.merge(extra_env)) do
        with_redis_stub(redis) do
          yield(redis)
        end
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

    def admin_headers
      { "Authorization" => "Bearer admin-secret" }
    end

    def stub_searxng(results: 3.times.map { |index| searxng_result(index + 1) })
      stub_request(:get, "http://searxng:8080/")
        .with(query: hash_including("format" => "json"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({ results: results })
        )
    end

    def searxng_result(index)
      {
        title: "Result #{index}",
        url: "https://example#{index}.org/path?utm_source=test&b=2&a=1#fragment",
        content: "Snippet #{index}",
        engines: [ "google" ]
      }
    end

    def stub_exa(results:)
      stub_request(:post, "https://api.exa.ai/search")
        .with(headers: { "x-api-key" => "exa-key" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate({ results: results })
        )
    end

    def exa_result(index)
      {
        title: "Exa Result #{index}",
        url: "https://exa#{index}.example.org/path?utm_source=test#fragment",
        highlights: [ "Exa snippet #{index}" ]
      }
    end

    def cached_payload(request, status:, fresh_until:)
      JSON.generate(
        {
          "request_id" => "cached-request",
          "status" => "completed",
          "query" => request.query,
          "normalized_query" => request.normalized_query,
          "cache" => {
            "status" => status,
            "age_seconds" => 0,
            "generated_at" => 10.minutes.ago.utc.iso8601
          },
          "sources" => [ "searxng" ],
          "results" => [
            {
              "title" => "cached result",
              "url" => "https://example.org/cached",
              "canonical_url" => "https://example.org/cached",
              "snippet" => "cached snippet",
              "engines" => [ "google" ],
              "source" => "searxng",
              "rank" => 1,
              "published_at" => nil,
              "metadata" => {}
            }
          ],
          "warnings" => [],
          "timing_ms" => {},
          "fresh_until" => fresh_until.utc.iso8601
        }
      )
    end
  end
end
