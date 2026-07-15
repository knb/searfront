module V1
  class SearchRequestsController < ApplicationController
    def show
      result = Searfront::SearchRequestStatus.find(params[:id])

      render json: result.response, status: result.http_status
    rescue Searfront::SearchRequestStatus::NotFoundError => error
      render_error("not_found", error.message, :not_found, retryable: false)
    rescue Searfront::CacheUnavailableError => error
      render_error("cache_unavailable", error.message, :service_unavailable, retryable: true)
    end
  end
end
