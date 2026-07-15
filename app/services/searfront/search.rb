module Searfront
  class Search
    MINIMUM_RESULTS = 3

    def self.call(params:, request_id:)
      new(params, request_id).call
    end

    def initialize(params, request_id)
      @request = SearchParams.build(params)
      @request_id = request_id
      @cache = ResultCache.new
      @cache_key = CacheKey.for(request)
      @digest = CacheKey.digest_for(request)
      @request_status = RequestStatus.new
    end

    def call
      cached = cache.read(cache_key)
      return completed(cached, cache_status(cached)) if cache_usable?(cached)

      return cached_only_response(cached) if request.mode == "cache"

      SingleFlight.new(digest).synchronize do |lock_owner|
        refreshed = cache.read(cache_key)
        return completed(refreshed, cache_status(refreshed)) if cache_usable?(refreshed)
        return stale_response(refreshed, "single_flight_in_progress") unless lock_owner

        fetch_and_cache || fallback_response(refreshed || cached, "searxng_result_insufficient")
      end
    ensure
      cache.close
      request_status.close
    end

    private

    attr_reader :request, :request_id, :cache, :cache_key, :digest, :request_status

    def fetch_and_cache
      results = Clients::SearxngClient.new.search(request)
      merged = ResultMerger.call(results, limit: request.limit)
      return nil if merged.length < minimum_results

      response = base_response("miss", [ "searxng" ], merged)
      completed(cache.write(cache_key, response), "fresh")
    rescue UpstreamError
      nil
    end

    def cache_usable?(payload)
      payload && fresh?(payload) && !request.refresh
    end

    def fresh?(payload)
      Time.iso8601(payload.fetch("fresh_until")).future?
    rescue ArgumentError, KeyError
      false
    end

    def cache_status(payload)
      fresh?(payload) ? "fresh" : "stale"
    end

    def completed(payload, status)
      response = payload.except("fresh_until")
      generated_at = Time.iso8601(response.dig("cache", "generated_at"))
      response["cache"] = response["cache"].merge(
        "status" => status,
        "age_seconds" => (Time.current.utc - generated_at).to_i
      )
      response["warnings"] = response.fetch("warnings", [])
      response["warnings"] |= [ "stale_result" ] if status == "stale"

      SearchResult.new(http_status: :ok, response: response)
    end

    def stale_response(payload, warning)
      return raise UpstreamError, warning unless payload

      result = completed(payload, "stale")
      result.response["warnings"] |= [ warning ]
      result
    end

    def fallback_response(payload, warning)
      return stale_response(payload, warning) if payload

      enqueue_browser_search(warning)
    end

    def cached_only_response(payload)
      return stale_response(payload, "cache_mode_stale") if payload

      raise UpstreamError, "cache miss"
    end

    def base_response(cache_status, sources, results)
      {
        "request_id" => request_id,
        "status" => "completed",
        "query" => request.query,
        "normalized_query" => request.normalized_query,
        "cache" => {
          "status" => cache_status,
          "age_seconds" => 0,
          "generated_at" => Time.current.utc.iso8601
        },
        "sources" => sources,
        "results" => results,
        "warnings" => [],
        "timing_ms" => {}
      }
    end

    def enqueue_browser_search(warning)
      request_status.pending(request_id, cache_key)
      BrowserSearchJob.perform_later(request_id, request.to_h, cache_key)

      SearchResult.new(
        http_status: :accepted,
        response: {
          request_id: request_id,
          status: "pending",
          poll_after_seconds: 3,
          expires_at: request_expires_at.iso8601,
          warnings: [ "browser_fallback_queued", warning ]
        }
      )
    end

    def request_expires_at
      Time.current.utc + ENV.fetch("REQUEST_STATUS_TTL_SECONDS", 600).to_i
    end

    def minimum_results
      ENV.fetch("MINIMUM_RESULTS", MINIMUM_RESULTS).to_i
    end
  end
end
