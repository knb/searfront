require "digest"

module Searfront
  class ApiTokens
    def self.from_env
      new(ENV.fetch("SEARFRONT_API_TOKENS", ""))
    end

    def initialize(raw_tokens)
      @tokens = parse(raw_tokens)
    end

    def authenticate(secret)
      raise AuthenticationError, "Bearer token is required" if secret.blank?

      token = @tokens.find { |candidate| secure_match?(candidate.secret, secret) }
      raise AuthenticationError, "Bearer token is invalid" unless token

      token
    end

    private

    def parse(raw_tokens)
      raw_tokens.to_s.split(",").filter_map do |entry|
        id, secret, role = entry.strip.split(":", 3)
        next if id.blank? || secret.blank?

        ApiToken.new(id: id, secret: secret, role: role.presence || "user")
      end
    end

    def secure_match?(expected, actual)
      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(expected),
        Digest::SHA256.hexdigest(actual)
      )
    end
  end
end
