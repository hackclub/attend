# The MCP consent screen also collects per-connection privacy choices — which
# events the client may reach, and whether its responses are anonymized. Those
# live in the app, so the gem's authorizations controller is decorated here
# rather than forked. See ToolchestConnectionSettings.
Rails.application.config.to_prepare do
  unless Toolchest::Oauth::AuthorizationsController < ToolchestConnectionSettings
    Toolchest::Oauth::AuthorizationsController.include(ToolchestConnectionSettings)
  end
end
