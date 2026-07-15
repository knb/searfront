module Searfront
  class UrlCanonicalizer
    TRACKING_PARAMS = /\A(utm_|fbclid\z|gclid\z)/i

    def self.call(url)
      new(url).call
    end

    def initialize(url)
      @uri = URI.parse(url.to_s)
    end

    def call
      return nil unless %w[http https].include?(uri.scheme)

      uri.fragment = nil
      uri.host = uri.host&.downcase
      uri.port = nil if default_port?
      uri.query = canonical_query
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    private

    attr_reader :uri

    def default_port?
      (uri.scheme == "http" && uri.port == 80) || (uri.scheme == "https" && uri.port == 443)
    end

    def canonical_query
      return nil if uri.query.blank?

      pairs = URI.decode_www_form(uri.query)
        .reject { |key, _value| key.match?(TRACKING_PARAMS) }
        .sort_by { |key, value| [ key, value ] }

      pairs.empty? ? nil : URI.encode_www_form(pairs)
    end
  end
end
