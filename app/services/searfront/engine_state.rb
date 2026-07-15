module Searfront
  class EngineState
    def initialize(redis: RedisRegistry.build(:state))
      @redis = redis
    end

    def suspend(engine, reason:, duration:)
      payload = {
        status: "suspended",
        reason: reason,
        resume_at: (Time.current.utc + duration).iso8601
      }
      redis.set(key(engine), JSON.generate(payload), ex: duration)
    rescue Redis::BaseError => error
      raise CacheUnavailableError, error.message
    ensure
      redis.close
    end

    private

    attr_reader :redis

    def key(engine)
      "searfront:state:v1:engine:#{engine}"
    end
  end
end
