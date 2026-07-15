require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
  test "returns process health without authentication" do
    get "/healthz"

    assert_response :success
    body = response.parsed_body
    assert_equal "ok", body["status"]
    assert_equal "searfront", body["service"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, body["checked_at"])
  end
end
