module Docuseal
  # Which DocuSeal template a waiver consent is issued from. Shared by the
  # Create*WaiverJobs and by the callers that decide whether a failed waiver
  # is worth sending again.
  module WaiverTemplate
    # Template ids on the legacy cloud cluster (docuseal.com). They mean
    # nothing on any other host — the self-hosted cluster numbers its templates
    # from 1 — so they're only a fallback for consents pinned to legacy.
    LEGACY_DEFAULT_IDS = {
      minor_waiver: 2274072,
      adult_waiver: 2274072,
      freedom_waiver: 2274416
    }.freeze

    # Failure reasons that no amount of retrying fixes: the event's template
    # config is wrong, so an organiser has to change it first.
    CONFIG_FAILURE_PREFIXES = %w[template_not_configured template_not_found].freeze

    module_function

    def kind_for(consent)
      if consent.freedom_waiver?
        :freedom_waiver
      elsif consent.guardian_participant_event_id.present? || consent.participant_event.requires_guardian?
        :minor_waiver
      else
        :adult_waiver
      end
    end

    # nil when the event has no template for this kind and the consent's host
    # has no built-in default.
    def id_for(event:, host:, kind:)
      configured = case kind
      when :freedom_waiver then event.docuseal_freedom_waiver_template_id.presence
      when :minor_waiver then event.docuseal_waiver_template_id.presence
      when :adult_waiver
        event.docuseal_waiver_template_id.presence || event.docuseal_adult_waiver_template_id.presence
      else raise ArgumentError, "unknown waiver kind #{kind.inspect}"
      end

      configured || (LEGACY_DEFAULT_IDS.fetch(kind) if legacy_host?(host))
    end

    def id_for_consent(consent, kind: kind_for(consent))
      id_for(event: consent.participant_event.event, host: consent.docuseal_host, kind: kind)
    end

    def legacy_host?(host)
      legacy = Docuseal::HostConfig.legacy_host
      legacy.present? && Docuseal.host(host) == legacy
    end

    def config_failure?(consent)
      consent.failed? && consent.failure_reason.to_s.start_with?(*CONFIG_FAILURE_PREFIXES)
    end

    # A failed waiver is worth re-sending unless it failed on template config
    # that nobody has changed since. Once an organiser points the event at a
    # different template, the next portal visit picks it up on its own.
    def retry_failed?(consent)
      return false unless consent.failed?
      return true unless config_failure?(consent)

      id_for_consent(consent).to_s != consent.docuseal_template_id.to_s
    end
  end
end
