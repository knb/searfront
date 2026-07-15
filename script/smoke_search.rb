require "json"
require "net/http"
require "uri"

base_url = ENV.fetch("SEARFRONT_BASE_URL", "http://localhost:3000")
token = ENV.fetch("SEARFRONT_TOKEN")
query = ENV.fetch("SEARFRONT_QUERY", "llama.cpp Vulkan")

def request_json(method, url, token)
  uri = URI(url)
  request = method.new(uri)
  request["Authorization"] = "Bearer #{token}"

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.request(request)
  end

  body = response.body.to_s.empty? ? {} : JSON.parse(response.body)
  [ response, body ]
end

ready_response, ready_body = request_json(Net::HTTP::Get, "#{base_url}/readyz", token)
abort("readyz failed: #{ready_response.code} #{ready_body}") unless ready_response.is_a?(Net::HTTPSuccess)

search_url = "#{base_url}/v1/search?q=#{URI.encode_www_form_component(query)}"
search_response, search_body = request_json(Net::HTTP::Get, search_url, token)

case search_response.code.to_i
when 200
  puts JSON.pretty_generate(search_body)
when 202
  request_id = search_body.fetch("request_id")
  sleep(search_body.fetch("poll_after_seconds", 3).to_i)
  poll_response, poll_body = request_json(Net::HTTP::Get, "#{base_url}/v1/search_requests/#{request_id}", token)
  abort("poll failed: #{poll_response.code} #{poll_body}") unless poll_response.is_a?(Net::HTTPSuccess)

  puts JSON.pretty_generate(poll_body)
else
  abort("search failed: #{search_response.code} #{search_body}")
end
