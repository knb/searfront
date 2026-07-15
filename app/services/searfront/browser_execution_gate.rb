module Searfront
  class BrowserExecutionGate
    def initialize(engine, redis: RedisRegistry.build(:state))
      @engine = engine
      @redis = redis
    end

    def wait
      sleep(wait_seconds)
      redis.set(last_run_key, Time.current.utc.iso8601)
    rescue Redis::BaseError => error
      raise CacheUnavailableError, error.message
    ensure
      redis.close
    end

    private

    attr_reader :engine, :redis

    def wait_seconds
      last_run_at = redis.get(last_run_key)
      return jitter_seconds unless last_run_at

      elapsed = Time.current.utc - Time.iso8601(last_run_at)
      [ min_interval_seconds - elapsed, 0 ].max + jitter_seconds
    rescue ArgumentError
      jitter_seconds
    end

    def last_run_key
      "searfront:state:v1:last_run:#{engine}"
    end

    def min_interval_seconds
      ENV.fetch("BROWSER_MIN_INTERVAL_SECONDS", 15).to_f
    end

    def jitter_seconds
      max = ENV.fetch("BROWSER_JITTER_SECONDS", 5).to_f
      return 0 if max <= 0

      rand * max
    end
  end
end
