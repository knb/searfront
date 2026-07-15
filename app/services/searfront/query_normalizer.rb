module Searfront
  class QueryNormalizer
    def self.call(value)
      normalized = value.to_s.unicode_normalize(:nfkc).gsub(/\s+/, " ").strip
      raise ValidationError, "q is required" if normalized.blank?
      raise ValidationError, "q is too long" if normalized.length > 500

      normalized
    end
  end
end
