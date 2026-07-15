require "securerandom"

module Searfront
  class SingleFlight
    LOCK_TTL_MS = 45_000
    RELEASE_SCRIPT = <<~LUA
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("DEL", KEYS[1])
      else
        return 0
      end
    LUA

    def initialize(digest, redis: RedisRegistry.build(:state))
      @key = "searfront:state:v1:lock:#{digest}"
      @redis = redis
      @token = SecureRandom.uuid
      @locked = false
    end

    def synchronize
      @locked = acquire
      return yield(false) unless locked

      yield(true)
    ensure
      release if locked
      redis.close
    end

    private

    attr_reader :key, :redis, :token, :locked

    def acquire
      redis.set(key, token, nx: true, px: lock_ttl_ms)
    rescue Redis::BaseError => error
      raise CacheUnavailableError, error.message
    end

    def release
      redis.eval(RELEASE_SCRIPT, keys: [ key ], argv: [ token ])
    rescue Redis::BaseError => error
      Rails.logger.warn({ event: "single_flight_release_failed", key: key, error: error.message }.to_json)
    end

    def lock_ttl_ms
      ENV.fetch("SINGLE_FLIGHT_LOCK_MS", LOCK_TTL_MS).to_i
    end
  end
end
