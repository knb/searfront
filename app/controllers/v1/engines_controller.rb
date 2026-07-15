module V1
  class EnginesController < ApplicationController
    before_action :require_admin!

    def index
      render json: Searfront::EngineState.new.all
    end

    def resume
      render json: Searfront::EngineState.new.resume(params[:name])
    rescue Searfront::CacheUnavailableError => error
      render_error("cache_unavailable", error.message, :service_unavailable, retryable: true)
    end
  end
end
