module V1
  class SearchesController < ApplicationController
    def show
      result = Searfront::Search.call(params: search_params, request_id: request.request_id)
      render json: result.response, status: result.http_status
    rescue Searfront::ValidationError => error
      render_error("invalid_request", error.message, :bad_request, retryable: false)
    rescue Searfront::UpstreamError => error
      render_error("upstream_error", error.message, :bad_gateway, retryable: true)
    rescue Searfront::CacheUnavailableError => error
      render_error("cache_unavailable", error.message, :service_unavailable, retryable: true)
    end

    private

    def search_params
      params.permit(:q, :language, :limit, :time_range, :mode, :refresh, :wait_seconds, categories: [])
    end
  end
end
