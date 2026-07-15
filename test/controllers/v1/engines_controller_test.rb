require "test_helper"

module V1
  class EnginesControllerTest < ActionDispatch::IntegrationTest
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

      def scan_each(match:)
        return enum_for(:scan_each, match: match) unless block_given?

        pattern = Regexp.escape(match).gsub("\\*", ".*")
        store.keys.grep(/\A#{pattern}\z/).each { |key| yield key }
      end

      def close; end

      private

      attr_reader :store
    end

    test "lists suspended engines for admin" do
      with_engine_env do
        Searfront::EngineState.new.suspend("google", reason: "captcha", duration: 1.hour)

        get "/v1/engines", headers: admin_headers
      end

      assert_response :success
      engine = response.parsed_body["engines"].first
      assert_equal "google", engine["engine"]
      assert_equal "suspended", engine["status"]
      assert_equal "captcha", engine["reason"]
    end

    test "resumes suspended engine" do
      with_engine_env do
        Searfront::EngineState.new.suspend("google", reason: "captcha", duration: 1.hour)

        post "/v1/engines/google/resume", headers: admin_headers
      end

      assert_response :success
      assert_equal true, response.parsed_body["resumed"]
    end

    test "rejects engine operations for non admin" do
      with_engine_env do
        get "/v1/engines", headers: user_headers
      end

      assert_response :forbidden
    end

    private

    def with_engine_env
      redis = FakeRedis.new({})
      with_env(
        "SEARFRONT_API_TOKENS" => "user:user-secret:user,admin:admin-secret:admin",
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

    def admin_headers
      { "Authorization" => "Bearer admin-secret" }
    end

    def user_headers
      { "Authorization" => "Bearer user-secret" }
    end
  end
end
