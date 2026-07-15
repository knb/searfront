require "test_helper"

module V1
  class CacheControllerTest < ActionDispatch::IntegrationTest
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

      def del(key)
        store.delete(key) ? 1 : 0
      end

      def close; end

      private

      attr_reader :store
    end

    test "deletes cache by search condition for admin" do
      with_cache_env do |redis|
        request = Searfront::SearchParams.build(ActionController::Parameters.new(q: "delete me"))
        key = Searfront::CacheKey.for(request)
        redis.set(key, "payload")

        delete "/v1/cache", params: { q: "delete me" }, headers: admin_headers

        assert_response :success
        assert_equal true, response.parsed_body["deleted"]
        assert_nil redis.get(key)
      end
    end

    test "rejects cache deletion for non admin" do
      with_cache_env do
        delete "/v1/cache", params: { q: "delete me" }, headers: user_headers
      end

      assert_response :forbidden
      assert_equal "forbidden", response.parsed_body.dig("error", "code")
    end

    private

    def with_cache_env
      store = {}
      redis = FakeRedis.new(store)
      with_env(
        "SEARFRONT_API_TOKENS" => "user:user-secret:user,admin:admin-secret:admin",
        "CACHE_REDIS_URL" => "redis://cache.example:6379/0"
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

    def admin_headers
      { "Authorization" => "Bearer admin-secret" }
    end

    def user_headers
      { "Authorization" => "Bearer user-secret" }
    end
  end
end
