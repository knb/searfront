module Searfront
  class RequestStatus
    TTL_SECONDS = 600

    def initialize(redis: RedisRegistry.build(:state))
      @redis = redis
    end

    def pending(request_id, cache_key)
      write(request_id, status: "pending", cache_key: cache_key)
    end

    def complete(request_id, cache_key)
      write(request_id, status: "completed", cache_key: cache_key)
    end

    def fail(request_id, message)
      write(request_id, status: "failed", message: message)
    end

    def read(request_id)
      payload = redis.get(key(request_id))
      return nil if payload.blank?

      JSON.parse(payload)
    rescue Redis::BaseError, JSON::ParserError => error
      raise CacheUnavailableError, error.message
    end

    def close
      redis.close
    end

    private

    attr_reader :redis

    def write(request_id, payload)
      redis.set(key(request_id), JSON.generate(payload.merge("updated_at" => Time.current.utc.iso8601)), ex: ttl_seconds)
    rescue Redis::BaseError => error
      raise CacheUnavailableError, error.message
    end

    def key(request_id)
      "searfront:state:v1:request:#{request_id}"
    end

    def ttl_seconds
      ENV.fetch("REQUEST_STATUS_TTL_SECONDS", TTL_SECONDS).to_i
    end
  end
end
