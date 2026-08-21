#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

query = ENV.fetch("SEARXNG_SMOKE_QUERY", "SearXNG")
minimum_results = ENV.fetch("SEARXNG_SMOKE_MIN_RESULTS", "1").to_i

begin
  if %w[1 true yes].include?(ENV["SEARXNG_SMOKE_STDIN"].to_s.downcase)
    payload = JSON.parse($stdin.read)
  else
    base_url = ENV.fetch("SEARXNG_BASE_URL", "http://127.0.0.1:8080/")
    uri = URI.join(base_url.end_with?("/") ? base_url : "#{base_url}/", "search")
    uri.query = URI.encode_www_form(q: query, format: "json", categories: "general")

    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: ENV.fetch("SEARXNG_SMOKE_OPEN_TIMEOUT", "5").to_i,
      read_timeout: ENV.fetch("SEARXNG_SMOKE_READ_TIMEOUT", "20").to_i
    ) { |http| http.get(uri.request_uri) }

    abort("SearXNG smoke HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)

    payload = JSON.parse(response.body)
  end
  results = payload.fetch("results")
  abort("SearXNG smoke returned #{results.length} results; expected at least #{minimum_results}") if results.length < minimum_results

  puts "SearXNG smoke passed: #{results.length} results"
rescue JSON::ParserError, KeyError => error
  abort("SearXNG smoke returned invalid JSON: #{error.message}")
end
