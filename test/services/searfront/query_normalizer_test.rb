require "test_helper"

class Searfront::QueryNormalizerTest < ActiveSupport::TestCase
  test "normalizes unicode and whitespace while preserving case" do
    assert_equal "LLama.cpp Vulkan", Searfront::QueryNormalizer.call(" ＬＬama.cpp　 Vulkan\n")
  end

  test "rejects blank query" do
    assert_raises(Searfront::ValidationError) do
      Searfront::QueryNormalizer.call(" 　")
    end
  end
end
