module Searfront
  module Clients
    class BrowserWorkerClient
      def initialize(
        base_url: ENV["BROWSER_SEARCH_WORKER_URL"].presence || ENV["BROWSER_WORKER_BASE_URL"],
        token: ENV["BROWSER_SEARCH_WORKER_TOKEN"].presence || ENV["BROWSER_WORKER_TOKEN"]
      )
        raise KeyError, "BROWSER_SEARCH_WORKER_URL is not configured" if base_url.blank?

        @base_url = base_url
        @token = token
      end

      def search(request_id:, request:, engine:)
        response = Faraday.post(endpoint) do |req|
          req.headers["Content-Type"] = "application/json"
          req.headers["Authorization"] = "Bearer #{token}" if token.present?
          req.body = JSON.generate(payload(request_id, request, engine))
        end
        raise UpstreamError, "Browser Worker returned #{response.status}" unless parseable_response?(response)

        parse(response.body, engine)
      rescue Faraday::Error, JSON::ParserError => error
        raise UpstreamError, error.message
      end

      private

      attr_reader :base_url, :token

      def endpoint
        URI.join(base_url, "/v1/search/#{worker_engine}").to_s
      end

      def parseable_response?(response)
        response.status.between?(200, 299) || response.status == 429
      end

      def payload(_request_id, request, _engine)
        {
          query: request.normalized_query,
          language: worker_language(request.language),
          country: browser_country,
          limit: [ request.limit, 10 ].min
        }
      end

      def parse(body, engine)
        payload = JSON.parse(body)
        status = payload.fetch("status")
        raise UpstreamError, "Browser Worker status is #{status}" unless %w[ok empty blocked].include?(status)

        {
          "status" => status,
          "engine" => payload["engine"].presence || "google-browser",
          "diagnostics" => diagnostics(payload),
          "error" => payload["error"] || {},
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

      def worker_engine
        "google"
      end

      def worker_language(language)
        language.to_s.split("-").first.presence || "ja"
      end

      def browser_country
        ENV.fetch("BROWSER_SEARCH_COUNTRY", "JP")
      end

      def diagnostics(payload)
        detected = payload["detected"] || {}
        {
          "captcha" => detected["captcha"] == true,
          "rate_limited" => detected["rate_limited"] == true,
          "consent_page" => detected["consent_page"] == true,
          "access_denied" => detected["captcha"] == true || detected["consent_page"] == true
        }
      end
    end
  end
end
