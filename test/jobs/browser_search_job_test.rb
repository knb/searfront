require "test_helper"

class BrowserSearchJobTest < ActiveJob::TestCase
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

  test "stores browser results and completes request" do
    with_browser_env do |redis|
      request = Searfront::SearchParams.build(ActionController::Parameters.new(q: "browser query"))
      cache_key = Searfront::CacheKey.for(request)
      stub_browser_worker

      BrowserSearchJob.perform_now("request-1", request.to_h, cache_key)

      status = JSON.parse(redis.get("searfront:state:v1:request:request-1"))
      cache_payload = JSON.parse(redis.get(cache_key))
      assert_equal "completed", status["status"]
      assert_equal cache_key, status["cache_key"]
      assert_equal "browser result", cache_payload.dig("results", 0, "title")
      assert_equal [ "browser" ], cache_payload["sources"]
    end
  end

  test "suspends engine and fails request on captcha diagnostics" do
    with_browser_env do |redis|
      request = Searfront::SearchParams.build(ActionController::Parameters.new(q: "captcha query"))
      cache_key = Searfront::CacheKey.for(request)
      stub_browser_worker(diagnostics: { captcha: true })

      assert_raises(Searfront::UpstreamError) do
        BrowserSearchJob.perform_now("request-2", request.to_h, cache_key)
      end

      status = JSON.parse(redis.get("searfront:state:v1:request:request-2"))
      engine = JSON.parse(redis.get("searfront:state:v1:engine:google"))
      assert_equal "failed", status["status"]
      assert_equal "suspended", engine["status"]
      assert_equal "captcha", engine["reason"]
    end
  end

  private

  def with_browser_env
    store = {}
    redis = FakeRedis.new(store)

    with_env(
      "CACHE_REDIS_URL" => "redis://cache.example:6379/0",
      "STATE_REDIS_URL" => "redis://state.example:6379/0",
      "BROWSER_WORKER_BASE_URL" => "http://browser-worker:3000/",
      "BROWSER_WORKER_TOKEN" => "worker-token",
      "BROWSER_MIN_INTERVAL_SECONDS" => "0",
      "BROWSER_JITTER_SECONDS" => "0"
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

  def stub_browser_worker(diagnostics: {})
    stub_request(:post, "http://browser-worker:3000/v1/search")
      .with(headers: { "Authorization" => "Bearer worker-token" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(
          {
            status: "ok",
            engine: "google",
            diagnostics: { captcha: false, rate_limited: false }.merge(diagnostics),
            results: [
              {
                title: "browser result",
                url: "https://example.org/browser?utm_source=x#top",
                snippet: "browser snippet"
              }
            ]
          }
        )
      )
  end
end
