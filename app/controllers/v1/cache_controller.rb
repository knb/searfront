module V1
  class CacheController < ApplicationController
    before_action :require_admin!

    def destroy
      result = Searfront::CacheDeletion.call(params: cache_params)
      render json: result
    rescue Searfront::ValidationError => error
      render_error("invalid_request", error.message, :bad_request, retryable: false)
    rescue Searfront::CacheUnavailableError => error
      render_error("cache_unavailable", error.message, :service_unavailable, retryable: true)
    end

    private

    def cache_params
      params.permit(:q, :language, :limit, :time_range, :mode, :refresh, :wait_seconds, categories: [])
    end
  end
end
