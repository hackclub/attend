# AppSignal Ruby gem configuration
# Visit our documentation for a list of all available configuration options.
# https://docs.appsignal.com/ruby/configuration/options.html
Appsignal.configure do |config|
  config.activate_if_environment("production")
  config.name = "Attend"
  # The application's Push API key is set via the APPSIGNAL_PUSH_API_KEY
  # environment variable.
  # https://docs.appsignal.com/ruby/configuration/options.html#option-push_api_key

  # Configure actions that should not be monitored by AppSignal.
  # For more information see our docs:
  # https://docs.appsignal.com/ruby/configuration/ignore-actions.html
  # config.ignore_actions << "ApplicationController#isup"

  # Configure errors that should not be recorded by AppSignal.
  # For more information see our docs:
  # https://docs.appsignal.com/ruby/configuration/ignore-errors.html
  # config.ignore_errors << "MyCustomError"
  #
  # Malformed requests: invalid UTF-8 in a path or query, a body that doesn't
  # parse as its Content-Type says, an oversized multipart boundary. Rails
  # answers each with a 400 before any of our code runs, so there's nothing
  # to fix; they're crawlers and vulnerability scanners, and only drowned out
  # real errors.
  config.ignore_errors += [
    "ActionController::BadRequest",
    "ActionDispatch::Http::Parameters::ParseError",
    "Rack::Multipart::BoundaryTooLongError"
  ]
end
