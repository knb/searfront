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

    def all
      engines = redis.scan_each(match: "#{prefix}*").each_with_object({}) do |key, result|
        engine = key.delete_prefix(prefix)
        result[engine] = JSON.parse(redis.get(key)).merge("engine" => engine)
      end

      { engines: engines.values.sort_by { |engine| engine.fetch("engine") } }
    rescue Redis::BaseError, JSON::ParserError => error
      raise CacheUnavailableError, error.message
    ensure
      redis.close
    end

    def resume(engine)
      deleted = redis.del(key(engine)).positive?
      {
        status: "ok",
        engine: engine,
        resumed: deleted
      }
    rescue Redis::BaseError => error
      raise CacheUnavailableError, error.message
    ensure
      redis.close
    end

    private

    attr_reader :redis

    def prefix
      "searfront:state:v1:engine:"
    end

    def key(engine)
      "#{prefix}#{engine}"
    end
  end
end
