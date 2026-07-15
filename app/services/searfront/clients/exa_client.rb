module Searfront
  module Clients
    class ExaClient
      DEFAULT_BASE_URL = "https://api.exa.ai/search"

      def initialize(base_url: ENV.fetch("EXA_BASE_URL", DEFAULT_BASE_URL), api_key: ENV["EXA_API_KEY"])
        raise KeyError, "EXA_API_KEY is not configured" if api_key.blank?

        @base_url = base_url
        @api_key = api_key
      end

      def search(request)
        response = Faraday.post(base_url) do |req|
          req.headers["Content-Type"] = "application/json"
          req.headers["x-api-key"] = api_key
          req.body = JSON.generate(payload(request))
        end
        raise UpstreamError, "Exa returned #{response.status}" unless response.status.between?(200, 299)

        parse(response.body)
      rescue Faraday::Error, JSON::ParserError => error
        raise UpstreamError, error.message
      end

      private

      attr_reader :base_url, :api_key

      def payload(request)
        {
          query: request.normalized_query,
          type: ENV.fetch("EXA_SEARCH_TYPE", "auto"),
          numResults: [ request.limit, 10 ].min,
          userLocation: ENV.fetch("EXA_USER_LOCATION", "JP"),
          contents: {
            highlights: true
          }
        }
      end

      def parse(body)
        JSON.parse(body).fetch("results", []).map.with_index(1) do |result, rank|
          canonical_url = UrlCanonicalizer.call(result["url"])
          next if canonical_url.blank?

          {
            "title" => result["title"].to_s,
            "url" => result["url"].to_s,
            "canonical_url" => canonical_url,
            "snippet" => snippet(result),
            "engines" => [ "exa" ],
            "source" => "exa",
            "rank" => rank,
            "published_at" => result["publishedDate"],
            "metadata" => {
              "id" => result["id"],
              "author" => result["author"],
              "favicon" => result["favicon"]
            }.compact
          }
        end.compact
      end

      def snippet(result)
        Array(result["highlights"]).find(&:present?).presence ||
          result["summary"].presence ||
          result["text"].to_s.truncate(500)
      end
    end
  end
end
