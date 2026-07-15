module Searfront
  module Clients
    class SearxngClient
      def initialize(base_url: ENV["SEARXNG_BASE_URL"])
        raise KeyError, "SEARXNG_BASE_URL is not configured" if base_url.blank?

        @base_url = base_url
      end

      def search(request)
        response = Faraday.get(base_url, query_params(request))
        raise UpstreamError, "SearXNG returned #{response.status}" unless response.status.between?(200, 299)

        parse(response.body)
      rescue Faraday::Error, JSON::ParserError => error
        raise UpstreamError, error.message
      end

      private

      attr_reader :base_url

      def query_params(request)
        {
          q: request.normalized_query,
          language: request.language,
          categories: request.categories.join(","),
          time_range: request.time_range,
          format: "json"
        }.compact
      end

      def parse(body)
        JSON.parse(body).fetch("results", []).map.with_index(1) do |result, rank|
          canonical_url = UrlCanonicalizer.call(result["url"])
          next if canonical_url.blank?

          {
            "title" => result["title"].to_s,
            "url" => result["url"].to_s,
            "canonical_url" => canonical_url,
            "snippet" => result["content"].to_s,
            "engines" => Array(result["engines"].presence || result["engine"].presence || "searxng").map(&:to_s),
            "source" => "searxng",
            "rank" => rank,
            "published_at" => result["publishedDate"],
            "metadata" => {}
          }
        end.compact
      end
    end
  end
end
