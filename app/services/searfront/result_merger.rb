module Searfront
  class ResultMerger
    def self.call(results, limit:)
      new(results, limit).call
    end

    def initialize(results, limit)
      @results = results
      @limit = limit
    end

    def call
      grouped_results.first(limit).map.with_index(1) do |result, rank|
        result.merge("rank" => rank)
      end
    end

    private

    attr_reader :results, :limit

    def grouped_results
      results.each_with_object({}) do |result, grouped|
        canonical_url = result["canonical_url"]
        next if canonical_url.blank?

        grouped[canonical_url] = merge(grouped[canonical_url], result)
      end.values.sort_by { |result| [ result["score"], result["canonical_url"] ] }.map { |result| result.except("score") }
    end

    def merge(existing, incoming)
      return incoming.merge("score" => reciprocal_rank(incoming)) unless existing

      existing.merge(
        "engines" => (existing["engines"] + incoming["engines"]).uniq.sort,
        "score" => existing["score"] + reciprocal_rank(incoming),
        "snippet" => better_snippet(existing["snippet"], incoming["snippet"])
      )
    end

    def reciprocal_rank(result)
      -1.0 / result["rank"].to_i
    end

    def better_snippet(current, incoming)
      incoming.to_s.length > current.to_s.length ? incoming : current
    end
  end
end
