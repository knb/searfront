module Searfront
  class RedisRegistry
    URL_ENV = {
      cache: "CACHE_REDIS_URL",
      state: "STATE_REDIS_URL",
      sidekiq: "SIDEKIQ_REDIS_URL"
    }.freeze

    def self.build(name)
      env_name = URL_ENV.fetch(name)
      url = ENV[env_name]
      raise KeyError, "#{env_name} is not configured" if url.blank?

      Redis.new(url: url)
    end
  end
end
