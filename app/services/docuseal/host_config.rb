module Docuseal
  DEFAULT_HOST = "docuseal.com".freeze

  # Module-level helpers live here (not in a separate docuseal.rb) because
  # Zeitwerk's explicit-namespace handling races with eager-load: when files
  # in app/services/docuseal/ load first they claim the `Docuseal` constant,
  # so the sibling docuseal.rb is silently skipped and these helpers go
  # missing. Keeping them in a file that's known to load avoids the race.
  def self.host(override = nil)
    raw = override || Docuseal::HostConfig.default_host
    raw.to_s.sub(%r{\Ahttps?://}, "").chomp("/")
  end

  def self.base_url(host: nil)
    "https://#{self.host(host)}"
  end

  def self.signing_url(slug, host: nil)
    "#{base_url(host: host)}/s/#{slug}"
  end

  # Resolves DocuSeal clusters (legacy cloud + self-hosted) from credentials.
  #
  # Expected credentials layout:
  #
  #   docuseal:
  #     default_cluster: selfhosted
  #     legacy:
  #       host: https://api.docuseal.com        # full API base URL
  #       api_key: ...
  #       webhook_secret: ...
  #     selfhosted:
  #       host: https://signatures.hackclub.com/api
  #       api_key: ...
  #       webhook_secret: ...
  #
  # `host` is the API base URL (used by Faraday). The "embed host" — used for
  # iframe scripts, signing URLs, CSP origins, and as the per-record host
  # identifier — is derived by stripping the scheme and any leading `api.`.
  module HostConfig
    RESERVED_KEYS = %i[default_cluster].freeze

    # All new records (events, consents, templates) are provisioned on the
    # self-hosted cluster, regardless of the `default_cluster` credential.
    # Existing records keep whatever host they were created on. We pin the
    # cluster *name* (not the literal URL) so moving the self-hosted box only
    # needs a credentials change, not a code change.
    NEW_RECORD_CLUSTER = "selfhosted".freeze

    module_function

    def creds
      Rails.application.credentials.docuseal || {}
    end

    def cluster_names
      creds.keys
           .reject { |k| RESERVED_KEYS.include?(k) }
           .select { |k| creds[k].is_a?(Hash) }
           .map(&:to_s)
    end

    def cluster(name)
      creds[name.to_sym] || {}
    end

    def default_cluster_name
      (creds[:default_cluster] || "legacy").to_s
    end

    def default_host
      # Pinned to the self-hosted cluster for all new records. Falls back to
      # the credential-driven default cluster only if self-hosted isn't
      # configured in this environment.
      embed_host_for(NEW_RECORD_CLUSTER) || embed_host_for(default_cluster_name)
    end

    def legacy_host
      embed_host_for("legacy")
    end

    def all_hosts
      cluster_names.map { |n| embed_host_for(n) }.compact.uniq
    end

    # Bare host (no scheme, no `api.` prefix) used to identify the cluster
    # on a record and for CSP / script-src / signing URLs.
    def embed_host_for(cluster_name)
      raw = cluster(cluster_name)[:host].to_s
      return nil if raw.blank?
      stripped = raw.sub(%r{\Ahttps?://}, "").sub(%r{/.*\z}, "")
      stripped.sub(/\Aapi\./, "")
    end

    # Resolve a record's stored embed host to its cluster settings.
    def for_host(host)
      host = host.presence || default_host
      # Normalize the same way embed_host_for does (strip scheme/trailing
      # path and any leading api.) so a stored value like
      # "https://sign.example.com" still matches the bare cluster host.
      # Without this, a scheme'd value matches nothing and silently falls
      # through to legacy creds -> 403 "Not Authorized" against the wrong cluster.
      host = host.to_s.sub(%r{\Ahttps?://}, "").sub(%r{/.*\z}, "").sub(/\Aapi\./, "")
      cluster_name = cluster_names.find { |n| embed_host_for(n) == host }

      if cluster_name
        cfg = cluster(cluster_name)
        {
          host: host,
          api_base_url: cfg[:host],
          api_key: cfg[:api_key],
          webhook_secret: cfg[:webhook_secret]
        }
      else
        # Unknown host (probably a record from before this code shipped).
        # Treat as legacy and reuse legacy creds.
        legacy_cfg = cluster("legacy")
        {
          host: host,
          api_base_url: legacy_cfg[:host] || "https://api.#{host}",
          api_key: legacy_cfg[:api_key],
          webhook_secret: legacy_cfg[:webhook_secret]
        }
      end
    end

    # All configured webhook secrets across clusters. The webhook receiver
    # accepts any of them so both hosts can keep delivering during the bridge.
    def webhook_secrets
      cluster_names.map { |n| cluster(n)[:webhook_secret] }.compact.uniq
    end
  end
end
