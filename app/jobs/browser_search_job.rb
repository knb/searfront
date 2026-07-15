class BrowserSearchJob < ApplicationJob
  queue_as :browser_search

  def perform(request_id, canonical_params, cache_key)
    Searfront::BrowserSearch.new(
      request_id: request_id,
      canonical_params: canonical_params,
      cache_key: cache_key
    ).call
  end
end
