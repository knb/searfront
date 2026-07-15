require "test_helper"

class Searfront::CacheKeyTest < ActiveSupport::TestCase
  test "uses stable digest for equivalent category order" do
    first = Searfront::SearchParams.build(
      ActionController::Parameters.new(q: "llama.cpp", categories: %w[general news])
    )
    second = Searfront::SearchParams.build(
      ActionController::Parameters.new(q: "llama.cpp", categories: %w[news general])
    )

    assert_equal Searfront::CacheKey.for(first), Searfront::CacheKey.for(second)
  end
end
