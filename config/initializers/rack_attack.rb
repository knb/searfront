require "digest"

class Rack::Attack
  Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

  throttle("requests by token or ip", limit: ->(_request) { ENV.fetch("SEARFRONT_RATE_LIMIT_PER_MINUTE", 60).to_i }, period: 1.minute) do |request|
    authorization = request.get_header("HTTP_AUTHORIZATION").to_s
    token = authorization.delete_prefix("Bearer ").presence
    token ? Digest::SHA256.hexdigest(token) : request.ip
  end

  self.throttled_responder = lambda do |_request|
    [
      429,
      { "Content-Type" => "application/json" },
      [
        JSON.generate(
          error: {
            code: "rate_limited",
            message: "Rate limit exceeded"
          },
          retryable: true
        )
      ]
    ]
  end
end

Rails.application.config.middleware.use Rack::Attack
