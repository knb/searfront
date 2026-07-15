require "test_helper"

module Searfront
  class BrowserWorkerClientTest < ActiveSupport::TestCase
    test "posts to google search worker and maps results" do
      request = SearchParams.build(ActionController::Parameters.new(q: "browser query", language: "ja-JP", limit: 20))
      stub_request(:post, "http://browser-search-worker:3000/v1/search/google")
        .with(
          headers: { "Authorization" => "Bearer worker-token" },
          body: JSON.generate(
            {
              query: "browser query",
              language: "ja",
              country: "JP",
              limit: 10
            }
          )
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate(
            {
              engine: "google-browser",
              query: "browser query",
              status: "ok",
              results: [
                {
                  position: 1,
                  title: "Browser result",
                  url: "https://example.org/path?utm_source=x#top",
                  content: "Browser snippet"
                }
              ],
              detected: {
                captcha: false,
                consent_page: false,
                rate_limited: false
              },
              elapsed_ms: 123
            }
          )
        )

      with_browser_worker_env do
        response = Clients::BrowserWorkerClient.new.search(request_id: "request-1", request: request, engine: "google")

        assert_equal "ok", response["status"]
        assert_equal "google-browser", response["engine"]
        assert_equal "Browser result", response.dig("results", 0, "title")
        assert_equal "Browser snippet", response.dig("results", 0, "snippet")
        assert_equal [ "google-browser" ], response.dig("results", 0, "engines")
      end
    end

    test "returns blocked diagnostics for CAPTCHA responses" do
      request = SearchParams.build(ActionController::Parameters.new(q: "captcha query"))
      stub_request(:post, "http://browser-search-worker:3000/v1/search/google")
        .to_return(
          status: 429,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate(
            {
              engine: "google-browser",
              query: "captcha query",
              status: "blocked",
              results: [],
              error: {
                code: "google_captcha",
                message: "Google CAPTCHA page was detected.",
                retryable: false,
                suspend_seconds: 86_400
              },
              detected: {
                captcha: true,
                consent_page: false,
                rate_limited: false
              },
              elapsed_ms: 123
            }
          )
        )

      with_browser_worker_env do
        response = Clients::BrowserWorkerClient.new.search(request_id: "request-2", request: request, engine: "google")

        assert_equal "blocked", response["status"]
        assert_equal true, response.dig("diagnostics", "captcha")
        assert_equal "google_captcha", response.dig("error", "code")
      end
    end

    test "raises upstream error for unauthorized worker responses" do
      request = SearchParams.build(ActionController::Parameters.new(q: "auth query"))
      stub_request(:post, "http://browser-search-worker:3000/v1/search/google")
        .to_return(status: 401, body: JSON.generate(error: { code: "unauthorized" }))

      with_browser_worker_env do
        assert_raises(UpstreamError) do
          Clients::BrowserWorkerClient.new.search(request_id: "request-3", request: request, engine: "google")
        end
      end
    end

    private

    def with_browser_worker_env
      with_env(
        "BROWSER_SEARCH_WORKER_URL" => "http://browser-search-worker:3000/",
        "BROWSER_SEARCH_WORKER_TOKEN" => "worker-token"
      ) do
        yield
      end
    end
  end
end
