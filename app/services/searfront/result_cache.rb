module Searfront
  class ResultCache
    RESULT_TTL_SECONDS = 1_800
    STALE_TTL_SECONDS = 43_200

    def initialize(redis: RedisRegistry.build(:cache))
      @redis = redis
    end

    def read(key)
      payload = redis.get(key)
      return nil if payload.blank?

      JSON.parse(payload)
    rescue Redis::BaseError, JSON::ParserError => error
      raise CacheUnavailableError, error.message
    end

    def write(key, response, generated_at: Time.current.utc)
      fresh_until = generated_at + result_ttl_seconds
      payload = response.merge(
        "cache" => {
          "status" => "fresh",
          "age_seconds" => 0,
          "generated_at" => generated_at.iso8601
        },
        "fresh_until" => fresh_until.iso8601
      )

      redis.set(key, JSON.generate(payload), ex: stale_ttl_seconds)
      payload
    rescue Redis::BaseError => error
      raise CacheUnavailableError, error.message
    end

    def close
      redis.close
    end

    private

    attr_reader :redis

    def result_ttl_seconds
      ENV.fetch("SEARCH_RESULT_TTL_SECONDS", RESULT_TTL_SECONDS).to_i
    end

    def stale_ttl_seconds
      ENV.fetch("SEARCH_STALE_TTL_SECONDS", STALE_TTL_SECONDS).to_i
    end
  end
end
