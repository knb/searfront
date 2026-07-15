class ReadinessController < ApplicationController
  def show
    result = Searfront::ReadinessCheck.call
    status = result[:ready] ? :ok : :service_unavailable

    render json: result.except(:ready), status: status
  end
end
