require "digest"

module Searfront
  class StructuredLogger
    def self.log(request:, response:, duration_ms:)
      new(request, response, duration_ms).log
    end

    def initialize(request, response, duration_ms)
      @request = request
      @response = response
      @duration_ms = duration_ms
    end

    def log
      Rails.logger.info(payload.compact.to_json)
    end

    private

    attr_reader :request, :response, :duration_ms

    def payload
      {
        event: "request",
        request_id: request.request_id,
        method: request.request_method,
        path: request.path,
        controller: request.path_parameters[:controller],
        action: request.path_parameters[:action],
        status: response.status,
        duration_ms: duration_ms,
        query_digest: query_digest,
        query_length: query_length
      }
    end

    def query
      request.params[:q].to_s.presence
    end

    def query_digest
      Digest::SHA256.hexdigest(query) if query
    end

    def query_length
      query&.length
    end
  end
end
