require "net/http"

# Endpoints that generate interesting telemetry for SolarWinds APM.
class DemoController < ApplicationController
  def index
    render json: {
      service: ENV.fetch("OTEL_SERVICE_NAME", "rails-swo-demo"),
      solarwinds_apm: SolarWindsAPM::Version::STRING,
      apm_ready: SolarWindsAPM::API.solarwinds_ready?(0),
      endpoints: {
        "GET  /items"    => "ActiveRecord query (SQLite)",
        "POST /items"    => "ActiveRecord insert, body: {\"name\":\"x\",\"quantity\":1}",
        "GET  /slow"     => "Custom spans via SolarWindsAPM::API.in_span + random latency",
        "GET  /external" => "Outbound Net::HTTP call",
        "GET  /error"    => "Raises an exception (500)",
        "GET  /trace"    => "Current trace context",
        "GET  /health"   => "Health check (dropped by gateway tail sampling)"
      }
    }
  end

  def slow
    delay = rand(0.1..1.5).round(3)

    SolarWindsAPM::API.in_span("demo.slow_work", attributes: { "demo.delay_s" => delay }) do |span|
      sleep delay
      span&.add_event("slept")
    end

    SolarWindsAPM::API.in_span("demo.db_report") do
      Item.group(:name).sum(:quantity)
    end

    self.class.slow_counter&.add(1, attributes: { "demo.bucket" => delay > 1 ? "slow" : "fast" })
    Rails.logger.info("slow request finished delay=#{delay}")
    render json: { slept_seconds: delay }
  end

  def external
    url = URI(ENV.fetch("EXTERNAL_URL", "https://example.com/"))
    res = Net::HTTP.get_response(url)
    render json: { url: url.to_s, status: res.code.to_i, bytes: res.body.to_s.bytesize }
  end

  def error
    SolarWindsAPM::API.set_transaction_name("demo-error")
    raise StandardError, "Intentional demo error at #{Time.now.utc.iso8601}"
  end

  def trace
    info = SolarWindsAPM::API.current_trace_info
    render json: { trace_id: info.trace_id, span_id: info.span_id, tracestring: info.tracestring }
  end

  # Custom OTel metric; no-op when solarwinds_apm is disabled (e.g. no service key).
  def self.slow_counter
    return @slow_counter if defined?(@slow_counter)

    @slow_counter =
      if ::OpenTelemetry.respond_to?(:meter_provider)
        ::OpenTelemetry.meter_provider.meter("rails-swo-demo")
                       .create_counter("demo.slow.requests", unit: "{request}", description: "Requests to /slow")
      end
  end
end
