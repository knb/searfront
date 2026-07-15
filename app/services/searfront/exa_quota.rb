module Searfront
  class ExaQuota
    DEFAULT_DAILY_LIMIT = 500

    def initialize(redis: RedisRegistry.build(:state), now: Time.current.utc)
      @redis = redis
      @now = now
    end

    def consume
      limit = ENV.fetch("EXA_DAILY_LIMIT", DEFAULT_DAILY_LIMIT).to_i
      return false if limit <= 0

      count = redis.incr(key)
      redis.expire(key, ttl_seconds) if count == 1
      count <= limit
    rescue Redis::BaseError => error
      raise CacheUnavailableError, error.message
    ensure
      redis.close
    end

    private

    attr_reader :redis, :now

    def key
      "searfront:state:v1:exa:requests:#{now.strftime("%Y%m%d")}"
    end

    def ttl_seconds
      tomorrow = now.tomorrow.beginning_of_day
      (tomorrow - now).to_i + 3_600
    end
  end
end
