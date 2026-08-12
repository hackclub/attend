# Distributed tracing via OpenTelemetry. Traces are exported over OTLP only
# when an endpoint is configured (i.e. in deployed environments), so local
# development and tests stay quiet.
if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].present?
  require "opentelemetry/sdk"
  require "opentelemetry/exporter/otlp"
  require "opentelemetry/instrumentation/all"

  OpenTelemetry::SDK.configure do |c|
    c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "attend")
    c.use_all
  end
end
