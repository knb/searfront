require "test_helper"

module Searfront
  class ExaClientTest < ActiveSupport::TestCase
    test "posts to Exa search API and maps results" do
      request = SearchParams.build(ActionController::Parameters.new(q: "exa query", limit: 5))
      stub_request(:post, "https://api.exa.ai/search")
        .with(
          headers: { "x-api-key" => "exa-key" },
          body: JSON.generate(
            {
              query: "exa query",
              type: "auto",
              numResults: 5,
              userLocation: "JP",
              contents: {
                highlights: true
              }
            }
          )
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate(
            {
              results: [
                {
                  title: "Exa result",
                  url: "https://example.org/exa?utm_source=x#top",
                  publishedDate: "2026-07-15T00:00:00.000Z",
                  highlights: [ "Exa highlight" ],
                  id: "exa-id"
                }
              ]
            }
          )
        )

      with_env("EXA_API_KEY" => "exa-key") do
        results = Clients::ExaClient.new.search(request)

        assert_equal 1, results.length
        assert_equal "Exa result", results.first["title"]
        assert_equal "Exa highlight", results.first["snippet"]
        assert_equal [ "exa" ], results.first["engines"]
        assert_equal "exa", results.first["source"]
      end
    end

    test "requires an API key" do
      assert_raises(KeyError) { Clients::ExaClient.new(api_key: nil) }
    end
  end
end
