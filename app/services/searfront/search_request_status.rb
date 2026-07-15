module Searfront
  class SearchRequestStatus
    class NotFoundError < StandardError; end

    def self.find(request_id)
      new(request_id).find
    end

    def initialize(request_id)
      @request_id = request_id
      @status = RequestStatus.new
      @cache = ResultCache.new
    end

    def find
      payload = status.read(request_id)
      raise NotFoundError, "request_id is unknown or expired" unless payload

      case payload.fetch("status")
      when "pending"
        SearchResult.new(http_status: :accepted, response: pending_response)
      when "completed"
        completed_response(payload.fetch("cache_key"))
      when "failed"
        failed_response(payload)
      else
        raise NotFoundError, "request_id is unknown or expired"
      end
    ensure
      status.close
      cache.close
    end

    private

    attr_reader :request_id, :status, :cache

    def pending_response
      {
        status: "pending",
        request_id: request_id,
        poll_after_seconds: 3,
        warnings: []
      }
    end

    def completed_response(cache_key)
      payload = cache.read(cache_key)
      raise NotFoundError, "request_id is unknown or expired" unless payload

      response = payload.except("fresh_until")
      SearchResult.new(http_status: :ok, response: response)
    end

    def failed_response(payload)
      SearchResult.new(
        http_status: :bad_gateway,
        response: {
          status: "failed",
          request_id: request_id,
          error: {
            code: "browser_search_failed",
            message: payload["message"].presence || "Browser search failed"
          },
          retryable: true
        }
      )
    end
  end
end
