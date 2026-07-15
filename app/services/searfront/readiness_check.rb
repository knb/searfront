module Searfront
  class ReadinessCheck
    REDIS_CHECKS = {
      cache_redis: :cache,
      state_redis: :state,
      sidekiq_redis: :sidekiq
    }.freeze

    def self.call
      new.call
    end

    def call
      checks = REDIS_CHECKS.transform_values { |name| redis_check(name) }
      checks[:searxng] = searxng_check
      ready = checks.values.all? { |check| check[:status] == "ok" }

      {
        status: ready ? "ready" : "not_ready",
        ready: ready,
        checked_at: Time.current.utc.iso8601,
        checks: checks
      }
    end

    private

    def redis_check(name)
      measure do
        redis = RedisRegistry.build(name)
        ping = redis.ping
        raise "unexpected Redis ping response: #{ping.inspect}" unless ping == "PONG"
      ensure
        redis&.close
      end
    end

    def searxng_check
      base_url = ENV["SEARXNG_BASE_URL"]
      raise KeyError, "SEARXNG_BASE_URL is not configured" if base_url.blank?

      measure do
        response = Faraday.get(base_url)
        raise "unexpected SearXNG status: #{response.status}" unless response.status.between?(200, 399)
      end
    rescue KeyError => error
      failed_check(error)
    end

    def measure
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield

      {
        status: "ok",
        latency_ms: elapsed_ms(started_at)
      }
    rescue StandardError => error
      failed_check(error, started_at: started_at)
    end

    def failed_check(error, started_at: nil)
      check = {
        status: "error",
        error: error.class.name,
        message: error.message
      }
      check[:latency_ms] = elapsed_ms(started_at) if started_at
      check
    end

    def elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
    end
  end
end
