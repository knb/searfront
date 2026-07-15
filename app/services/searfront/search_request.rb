module Searfront
  SearchRequest = Data.define(
    :query,
    :normalized_query,
    :language,
    :limit,
    :categories,
    :time_range,
    :mode,
    :refresh,
    :wait_seconds
  )
end
