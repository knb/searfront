class ApplicationController < ActionController::API
  before_action :set_request_id_header
  before_action :authenticate_request!
  around_action :log_request

  attr_reader :current_api_token

  rescue_from Searfront::AuthenticationError do |error|
    render_error("unauthorized", error.message, :unauthorized, retryable: false)
  end

  private

  def authenticate_request!
    token = bearer_token
    @current_api_token = Searfront::ApiTokens.from_env.authenticate(token)
  end

  def bearer_token
    authorization = request.authorization.to_s
    scheme, token = authorization.split(/\s+/, 2)

    return token if scheme&.casecmp("Bearer")&.zero? && token.present?

    nil
  end

  def require_admin!
    return if current_api_token&.role == "admin"

    render_error("forbidden", "Admin role is required", :forbidden, retryable: false)
  end

  def set_request_id_header
    response.set_header("X-Request-ID", request.request_id)
  end

  def render_error(code, message, status, retryable:)
    render json: {
      error: {
        code: code,
        message: message
      },
      retryable: retryable,
      request_id: request.request_id
    }, status: status
  end

  def log_request
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
    Searfront::StructuredLogger.log(request: request, response: response, duration_ms: duration_ms)
  end
end
