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

  # Generate session nonces for permitted importmap and inline scripts.
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src]

  # Report violations without enforcing the policy initially.
  # Set to false once you've verified the policy works correctly.
  config.content_security_policy_report_only = true
end
