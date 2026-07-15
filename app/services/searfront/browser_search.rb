module Searfront
  class BrowserSearch
    DEFAULT_ENGINE = "google"

    def initialize(request_id:, canonical_params:, cache_key:)
      @request_id = request_id
      @request = SearchRequest.new(**canonical_params.symbolize_keys)
      @cache_key = cache_key
      @cache = ResultCache.new
      @status = RequestStatus.new
      @engine = ENV.fetch("BROWSER_SEARCH_ENGINE", DEFAULT_ENGINE)
    end

    def call
      existing = cache.read(cache_key)
      return status.complete(request_id, cache_key) if existing && fresh?(existing)

      raise UpstreamError, "Browser engine is suspended" if EngineState.new.suspended?(engine)

      BrowserExecutionGate.new(engine).wait
      worker_response = Clients::BrowserWorkerClient.new.search(request_id: request_id, request: request, engine: engine)
      handle_diagnostics(worker_response)

      merged = ResultMerger.call(worker_response.fetch("results"), limit: request.limit)
      raise UpstreamError, "Browser Worker returned insufficient results" if merged.empty?

      cache.write(cache_key, base_response(merged), generated_at: Time.current.utc)
      status.complete(request_id, cache_key)
    rescue StandardError => error
      status.fail(request_id, error.message)
      raise
    ensure
      cache.close
      status.close
    end

    private

    attr_reader :request_id, :request, :cache_key, :cache, :status, :engine

    def handle_diagnostics(worker_response)
      diagnostics = worker_response.fetch("diagnostics", {})
      if diagnostics["captcha"] || diagnostics["access_denied"]
        EngineState.new.suspend(engine, reason: "captcha", duration: captcha_suspend_seconds)
        raise UpstreamError, worker_error_message(worker_response, "Browser Worker detected CAPTCHA or access denied")
      end

      return unless diagnostics["rate_limited"]

      EngineState.new.suspend(engine, reason: "rate_limited", duration: rate_limit_suspend_seconds)
      raise UpstreamError, worker_error_message(worker_response, "Browser Worker detected rate limit")
    end

    def fresh?(payload)
      Time.iso8601(payload.fetch("fresh_until")).future?
    rescue ArgumentError, KeyError
      false
    end

    def base_response(results)
      {
        "request_id" => request_id,
        "status" => "completed",
        "query" => request.query,
        "normalized_query" => request.normalized_query,
        "cache" => {
          "status" => "miss",
          "age_seconds" => 0,
          "generated_at" => Time.current.utc.iso8601
        },
        "sources" => [ "browser" ],
        "results" => results,
        "warnings" => [],
        "timing_ms" => {}
      }
    end

    def captcha_suspend_seconds
      ENV.fetch("CAPTCHA_SUSPEND_SECONDS", 86_400).to_i
    end

    def rate_limit_suspend_seconds
      ENV.fetch("RATE_LIMIT_SUSPEND_SECONDS", 7_200).to_i
    end

    def worker_error_message(worker_response, fallback)
      worker_response.dig("error", "message").presence || fallback
    end
  end
end
