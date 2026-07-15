class MetricsController < ApplicationController
  def show
    render plain: Searfront::Metrics.render, content_type: "text/plain; version=0.0.4; charset=utf-8"
  end
end
