# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

require Rails.root.join("app/services/docuseal/host_config")

Rails.application.configure do
  docuseal_origins = Docuseal::HostConfig.all_hosts.map { |h| "https://#{h}" }

  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data, "https://cdn.docuseal.com", *docuseal_origins
    policy.img_src     :self, :data, :https
    policy.object_src  :none
    policy.script_src  :self, "https://cdn.docuseal.com", *docuseal_origins, "https://cdn.cloudflare.com", "https://unpkg.com", "https://cdn.jsdelivr.net", "https://challenges.cloudflare.com", "https://plausible.io"
    policy.style_src   :self, :unsafe_inline, "https://cdn.docuseal.com", *docuseal_origins, "https://cdn.jsdelivr.net"
    policy.connect_src :self, "https://api.docuseal.com", *docuseal_origins, "ws://localhost:9876", "ws://127.0.0.1:9876", "https://challenges.cloudflare.com", "https://plausible.io"
    policy.frame_src   :self, *docuseal_origins, "https://challenges.cloudflare.com"
    policy.frame_ancestors :self
    policy.base_uri    :self
    policy.form_action :self, *docuseal_origins
  end

  # A fresh nonce per response for the importmap and our inline scripts. Not
  # the session id: that's stable for the life of the session, so it would be
  # reusable by an injected script and would sit in the page markup on every
  # render. Nothing here caches HTML, so per-response costs us nothing.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # Enforced, not report-only. script-src has no `unsafe-inline`, so injected
  # markup can't run: an <img onerror=...> smuggled into a participant's name
  # is inert even if some future template forgets to escape it. Keeping this
  # true means no inline <script> without a nonce and no inline event
  # handlers anywhere — spec/requests/content_security_policy_spec.rb checks
  # both on every render.
  config.content_security_policy_report_only = false
end
