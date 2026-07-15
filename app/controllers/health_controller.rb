class HealthController < ApplicationController
  skip_before_action :authenticate_request!

  def show
    render json: {
      status: "ok",
      service: "searfront",
      checked_at: Time.current.utc.iso8601
    }
  end
end
