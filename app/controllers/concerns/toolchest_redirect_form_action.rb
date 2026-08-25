# The MCP OAuth consent screen posts back to the app, and the server then
# 302s to the client's redirect_uri (poke.com, claude.ai, ...). Browsers
# enforce the consent page's form-action across that whole redirect chain,
# and MCP clients register arbitrary callback hosts, so the global allowlist
# in the CSP initializer can't name them. Instead, consent-flow responses
# append the one redirect_uri origin toolchest has already validated against
# the client's registration (validate_client! halts with a 400 on any
# mismatch before this before_action runs).
module ToolchestRedirectFormAction
  extend ActiveSupport::Concern

  included do
    content_security_policy do |policy|
      source = redirect_uri_form_action_source
      if source
        existing = policy.directives["form-action"] || []
        policy.form_action(*existing, source)
      end
    end
  end

  private

  def redirect_uri_form_action_source
    uri = URI.parse(params[:redirect_uri].to_s)
    if %w[http https].include?(uri.scheme) && uri.host.present?
      port = (":#{uri.port}" unless uri.port == uri.default_port)
      "#{uri.scheme}://#{uri.host}#{port}"
    elsif uri.scheme.present?
      # Native clients can register custom-scheme callbacks (cursor://...).
      "#{uri.scheme}:"
    end
  rescue URI::InvalidURIError
    nil
  end
end
