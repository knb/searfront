module Searfront
  module Clients
    class BrowserWorkerClient
      def initialize(base_url: ENV["BROWSER_WORKER_BASE_URL"], token: ENV["BROWSER_WORKER_TOKEN"])
        raise KeyError, "BROWSER_WORKER_BASE_URL is not configured" if base_url.blank?

        @base_url = base_url
        @token = token
      end

      def search(request_id:, request:, engine:)
        response = Faraday.post(endpoint) do |req|
          req.headers["Content-Type"] = "application/json"
          req.headers["Authorization"] = "Bearer #{token}" if token.present?
          req.body = JSON.generate(payload(request_id, request, engine))
        end
        raise UpstreamError, "Browser Worker returned #{response.status}" unless response.status.between?(200, 299)

        parse(response.body, engine)
      rescue Faraday::Error, JSON::ParserError => error
        raise UpstreamError, error.message
      end

      private

      attr_reader :base_url, :token

      def endpoint
        URI.join(base_url, "/v1/search").to_s
      end

      def payload(request_id, request, engine)
        {
          request_id: request_id,
          engine: engine,
          query: request.normalized_query,
          language: request.language,
          limit: request.limit,
          timeout_ms: browser_timeout_ms
        }
      end

      def parse(body, engine)
        payload = JSON.parse(body)
        raise UpstreamError, "Browser Worker status is #{payload["status"]}" unless payload["status"] == "ok"

        {
          "status" => payload["status"],
          "engine" => payload["engine"].presence || engine,
          "diagnostics" => payload["diagnostics"] || {},
          "results" => map_results(payload.fetch("results", []), payload["engine"].presence || engine)
        }
      end

      def map_results(results, engine)
        results.map.with_index(1) do |result, rank|
          canonical_url = UrlCanonicalizer.call(result["url"])
          next if canonical_url.blank?

          {
            "title" => result["title"].to_s,
            "url" => result["url"].to_s,
            "canonical_url" => canonical_url,
            "snippet" => result["snippet"].presence || result["content"].to_s,
            "engines" => [ engine.to_s ],
            "source" => "browser",
            "rank" => rank,
            "published_at" => result["published_at"],
            "metadata" => result["metadata"] || {}
          }
        end.compact
      end

      def browser_timeout_ms
        ENV.fetch("BROWSER_TIMEOUT_MS", 35_000).to_i
      end
    end
  end
end
