require "test_helper"

class Searfront::ApiTokensTest < ActiveSupport::TestCase
  test "authenticates configured bearer token" do
    tokens = Searfront::ApiTokens.new("agent:secret:user,admin:admin-secret:admin")

    token = tokens.authenticate("admin-secret")

    assert_equal "admin", token.id
    assert_equal "admin", token.role
  end

  test "rejects missing bearer token" do
    tokens = Searfront::ApiTokens.new("agent:secret:user")

    error = assert_raises(Searfront::AuthenticationError) do
      tokens.authenticate(nil)
    end
    assert_equal "Bearer token is required", error.message
  end

  test "rejects invalid bearer token" do
    tokens = Searfront::ApiTokens.new("agent:secret:user")

    error = assert_raises(Searfront::AuthenticationError) do
      tokens.authenticate("wrong")
    end
    assert_equal "Bearer token is invalid", error.message
  end
end
