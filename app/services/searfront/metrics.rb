module Searfront
  class Metrics
    class << self
      def increment(name, labels = {})
        counters[series_key(name, labels)] += 1
      end

      def observe(name, value, labels = {})
        observations[series_key(name, labels)] << value.to_f
      end

      def render
        [
          "# TYPE searfront_requests_total counter",
          render_counters("searfront_requests_total"),
          "# TYPE searfront_request_duration_seconds summary",
          render_observations("searfront_request_duration_seconds")
        ].join("\n")
      end

      def reset!
        counters.clear
        observations.clear
      end

      private

      def counters
        @counters ||= Hash.new(0)
      end

      def observations
        @observations ||= Hash.new { |hash, key| hash[key] = [] }
      end

      def series_key(name, labels)
        [ name, labels.transform_keys(&:to_s).sort.to_h ]
      end

      def render_counters(name)
        counters.filter_map do |(metric_name, labels), value|
          next unless metric_name == name

          "#{name}#{label_text(labels)} #{value}"
        end.join("\n")
      end

      def render_observations(name)
        observations.filter_map do |(metric_name, labels), values|
          next unless metric_name == name

          count = values.length
          sum = values.sum
          [
            "#{name}_count#{label_text(labels)} #{count}",
            "#{name}_sum#{label_text(labels)} #{format('%<value>.6f', value: sum)}"
          ].join("\n")
        end.join("\n")
      end

      def label_text(labels)
        return "" if labels.empty?

        formatted = labels.map { |key, value| "#{key}=#{value.to_s.inspect}" }.join(",")
        "{#{formatted}}"
      end
    end
  end
end
