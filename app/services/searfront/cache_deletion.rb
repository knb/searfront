module Searfront
  class CacheDeletion
    def self.call(params:)
      new(params).call
    end

    def initialize(params)
      @request = SearchParams.build(params)
      @redis = RedisRegistry.build(:cache)
    end

    def call
      key = CacheKey.for(request)
      deleted = redis.del(key).positive?

      {
        status: "ok",
        deleted: deleted,
        cache_key_digest: CacheKey.digest_for(request)
      }
    rescue Redis::BaseError => error
      raise CacheUnavailableError, error.message
    ensure
      redis.close
    end

    private

    attr_reader :request, :redis
  end
end
