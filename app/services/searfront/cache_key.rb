require "digest"

module Searfront
  class CacheKey
    VERSION = 1

    def self.for(request)
      new(request).key
    end

    def self.digest_for(request)
      new(request).digest
    end

    def initialize(request)
      @request = request
    end

    def key
      "searfront:cache:v#{VERSION}:result:#{digest}"
    end

    def digest
      Digest::SHA256.hexdigest(canonical_json)
    end

    private

    attr_reader :request

    def canonical_json
      JSON.generate(
        {
          version: VERSION,
          query: request.normalized_query,
          language: request.language,
          limit: request.limit,
          categories: request.categories.sort,
          time_range: request.time_range,
          safe_search: 0,
          mode_scope: "auto"
        }
      )
    end
  end
end
