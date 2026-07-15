module Searfront
  class SearchParams
    LANGUAGES = %w[ja-JP en-US].freeze
    TIME_RANGES = %w[day week month year].freeze
    MODES = %w[auto cache searxng browser].freeze
    DEFAULT_LANGUAGE = "ja-JP"
    DEFAULT_LIMIT = 10
    DEFAULT_CATEGORY = "general"

    def self.build(params)
      new(params).build
    end

    def initialize(params)
      @params = params
    end

    def build
      normalized_query = QueryNormalizer.call(params[:q])

      SearchRequest.new(
        query: params[:q].to_s,
        normalized_query: normalized_query,
        language: language,
        limit: limit,
        categories: categories,
        time_range: time_range,
        mode: mode,
        refresh: boolean(params[:refresh]),
        wait_seconds: wait_seconds
      )
    end

    private

    attr_reader :params

    def language
      value = params[:language].presence || DEFAULT_LANGUAGE
      raise ValidationError, "language is not supported" unless LANGUAGES.include?(value)

      value
    end

    def limit
      value = integer(params[:limit].presence || DEFAULT_LIMIT)
      raise ValidationError, "limit must be between 1 and 20" unless value.between?(1, 20)

      value
    end

    def categories
      values = Array(params[:categories].presence || DEFAULT_CATEGORY).flat_map { |value| value.to_s.split(",") }
      normalized = values.map { |value| value.unicode_normalize(:nfkc).strip }.reject(&:blank?).uniq.sort
      raise ValidationError, "categories is required" if normalized.empty?

      normalized
    end

    def time_range
      value = params[:time_range].presence
      return nil if value.blank?
      raise ValidationError, "time_range is not supported" unless TIME_RANGES.include?(value)

      value
    end

    def mode
      value = params[:mode].presence || "auto"
      raise ValidationError, "mode is not supported" unless MODES.include?(value)

      value
    end

    def wait_seconds
      value = integer(params[:wait_seconds].presence || 0)
      raise ValidationError, "wait_seconds must be between 0 and 30" unless value.between?(0, 30)

      value
    end

    def boolean(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def integer(value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ValidationError, "numeric parameter is invalid"
    end
  end
end
