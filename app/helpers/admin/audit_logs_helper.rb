module Admin
  module AuditLogsHelper
    SENSITIVE_FIELD_PATTERNS = /password|token|secret|api_key|otp|access_key/i

    # Columns holding an exact date of birth, a home address, or a phone number,
    # on participants, guardians, and emergency contacts alike. PII-restricted
    # roles (see EventRoleAssignment::PII_RESTRICTED_ROLES) can reach a
    # participant's change history, and a changeset is just as revealing as the
    # field itself.
    PII_FIELDS = %w[
      date_of_birth address_line_1 address_line_2 city state postal_code
      country country_of_residence
      phone phone_number phone_override
    ].freeze

    # The history page mixes in Guardian and EmergencyContact versions. A
    # participant's own email address is visible to PII-restricted roles; the
    # people around them still aren't.
    EMAIL_FIELDS = %w[email invited_via_email].freeze

    def audit_field_label(field)
      field.to_s.humanize
    end

    def audit_changed_field_pairs(changed_fields)
      return [] if changed_fields.blank?

      changed_fields.map do |field, change|
        if change.is_a?(Array) && change.length == 2
          [ field, change[0], change[1] ]
        else
          [ field, nil, change ]
        end
      end
    end

    # Returns a hash of {field => [old, new]} from a PaperTrail::Version.
    # Hides framework noise so the diff stays human-readable. Pass
    # `hide_pii: true` to also drop dates of birth, addresses, phone numbers,
    # and everyone-but-the-participant's email.
    def audit_version_changes(version, hide_pii: false)
      raw = (version.respond_to?(:changeset) ? version.changeset : nil) || {}
      cleaned = raw.except("updated_at", "created_at", "encrypted_password", "remember_created_at",
        "current_sign_in_at", "last_sign_in_at", "current_sign_in_ip", "last_sign_in_ip",
        "sign_in_count", "oidc_claims")
      return cleaned unless hide_pii

      hidden = PII_FIELDS
      hidden += EMAIL_FIELDS unless version.item_type == "Participant"
      cleaned.except(*hidden)
    rescue => e
      Rails.logger.warn("[AuditLog] Could not parse version #{version.id}: #{e.message}")
      {}
    end

    def audit_user_label(whodunnit, users_by_id = {})
      return "System" if whodunnit.blank?

      user = users_by_id[whodunnit] || User.find_by(id: whodunnit)
      user&.display_name_or_fallback || "User ##{whodunnit}"
    end

    def audit_format_value(field, value)
      return content_tag(:span, "—", class: "text-gray-400 italic") if value.nil? || value == ""

      if SENSITIVE_FIELD_PATTERNS.match?(field.to_s)
        return content_tag(:span, "[redacted]", class: "text-gray-400 italic")
      end

      formatted = case value
      when true then "yes"
      when false then "no"
      when Hash, Array then JSON.pretty_generate(value)
      when Time, DateTime, ActiveSupport::TimeWithZone then value.strftime("%Y-%m-%d %H:%M:%S %Z")
      when Date then value.strftime("%Y-%m-%d")
      else value.to_s
      end

      content_tag(:span, formatted, class: "whitespace-pre-wrap break-words")
    end
  end
end
