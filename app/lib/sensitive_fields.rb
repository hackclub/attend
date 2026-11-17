# The one registry of sensitive fields.
#
# Every place that has to know "is this field personal data?" reads from here:
# AuditLog redaction, the version-history filter (Admin::AuditLogsHelper), the
# anonymized-MCP response filter (Mcp::ResponseFilter), and the PII gates in
# the API and MCP serializers. Before this, each kept its own list and they
# drifted.
#
# Two tables, because the callers ask two different questions:
#
#   COLUMNS       model + column -> what it is. Used where the model is known
#                 (audit changesets, serializers).
#   RESPONSE_KEYS key in a JSON payload -> how an anonymized connection treats
#                 it. Keys, not columns: a payload says `dob` or `mailing_address`
#                 where no column does.
#
# Classes:
#   :pii          identifies or locates a person (birth date, address, phone, email)
#   :medical      health, dietary and accessibility detail
#   :safeguarding safeguarding detail
#
# `restricted: false` marks the few PII fields a PII-restricted role (see
# EventRoleAssignment::PII_RESTRICTED_ROLES) still sees: a participant's own
# email address, and an emergency contact's phone number.
module SensitiveFields
  REDACTED = "[REDACTED]".freeze

  Field = Data.define(:model, :name, :sensitivity, :kind, :restricted) do
    def pii? = sensitivity == :pii
  end

  def self.build(model, sensitivity, kind, names, restricted: true)
    names.map { |name| Field.new(model: model, name: name.to_s, sensitivity: sensitivity, kind: kind, restricted: restricted) }
  end
  private_class_method :build

  ADDRESS_COLUMNS = %w[address_line_1 address_line_2 city state postal_code].freeze

  COLUMNS = [
    *build("Participant", :pii, :birth_date, %w[date_of_birth]),
    *build("Participant", :pii, :address, ADDRESS_COLUMNS + %w[country_of_residence]),
    *build("Participant", :pii, :phone, %w[phone]),
    *build("Participant", :pii, :email, %w[email], restricted: false),

    *build("Guardian", :pii, :address, ADDRESS_COLUMNS + %w[country]),
    *build("Guardian", :pii, :phone, %w[phone]),
    *build("Guardian", :pii, :email, %w[email]),

    *build("GuardianParticipantEvent", :pii, :phone, %w[phone_override]),
    *build("GuardianParticipantEvent", :pii, :email, %w[invited_via_email]),

    *build("EmergencyContact", :pii, :name, %w[name]),
    *build("EmergencyContact", :pii, :phone, %w[phone], restricted: false),
    *build("EmergencyContact", :pii, :email, %w[email]),
    *build("EmergencyContact", :pii, :relationship, %w[relationship]),

    *build("Travel", :pii, :address, %w[origin_address]),

    *build("User", :pii, :phone, %w[phone_number]),

    *build("Medical", :medical, :health,
      %w[allergies allergy_severity medical_conditions medications emergency_action_plan
         additional_notes has_anaphylaxis_risk requires_refrigeration]),
    *build("Dietary", :medical, :health,
      %w[diet_type intolerances life_threatening_allergies cross_contamination_risk notes]),
    *build("Accessibility", :medical, :health,
      %w[mobility_needs sensory_needs communication_needs religious_practices other_needs
         neurodivergent_notes has_adhd has_autism has_dyslexia uses_wheelchair step_free_required
         needs_captioning needs_large_print needs_sign_language]),

    *build("SafeguardingInfo", :safeguarding, :safeguarding,
      %w[authorized_pickup_adults other_instructions high_support_notes high_support_flag
         can_leave_unaccompanied freedom_waiver_granted])
  ].freeze

  BY_MODEL = COLUMNS.group_by(&:model).transform_values { |fields| fields.index_by(&:name).freeze }.freeze

  # How an anonymized MCP connection treats a response key: person names
  # become initials, everything else here is replaced outright.
  RESPONSE_KEYS = {
    initials: %w[
      legal_name full_name preferred_name display_name participant_name
      guardian_name author sent_by reported_by last_updated_by assigned_to
      closed_by created_by from staff_names roommate_name occupant_name
      emergency_contact_name next_of_kin
    ],
    redact: %w[
      email emails email_address personal_email work_email guardian_email
      phone phone_number phone_numbers mobile mobile_number home_phone
      twilio_to_number from_number to_number guardian_phone
      emergency_contact_phone emergency_contact emergency_contacts
      slack_user_id slack_id discord_id
      date_of_birth dob
      address street_address address_line1 address_line2 mailing_address
      postal_code postcode zip zipcode city state
      passport_number national_id ip_address
    ]
  }.transform_values(&:freeze).freeze

  class << self
    def field(model, name)
      BY_MODEL.dig(model_name_for(model), name.to_s)
    end

    def sensitivity(model, name)
      field(model, name)&.sensitivity
    end

    def pii?(model, name)
      field(model, name)&.pii? || false
    end

    # Column names, de-duplicated across models. Narrow with `models:`,
    # `sensitivity:` and `kinds:`.
    def names(models: nil, sensitivity: nil, kinds: nil)
      models = Array(models).map { |model| model_name_for(model) } if models
      COLUMNS.select { |field|
        (models.nil? || models.include?(field.model)) &&
          (sensitivity.nil? || Array(sensitivity).include?(field.sensitivity)) &&
          (kinds.nil? || Array(kinds).include?(field.kind))
      }.map(&:name).uniq
    end

    # The columns of `model` a PII-restricted role may not see.
    def restricted_names(model)
      BY_MODEL.fetch(model_name_for(model), {}).values.select { |field| field.pii? && field.restricted }.map(&:name)
    end

    # Serializer gate: drops the keys of `attributes` that are restricted PII
    # on `model` unless the caller may see PII. Unregistered keys pass through,
    # so a gate only ever hides what the registry names.
    def visible(model, attributes, pii:)
      return attributes if pii

      hidden = restricted_names(model)
      attributes.reject { |key, _| hidden.include?(key.to_s) }
    end

    def response_keys(treatment)
      RESPONSE_KEYS.fetch(treatment)
    end

    # Redacts a changeset ({ field => [old, new] }) for storage in an audit
    # row: every `encrypts` attribute (so encrypted-at-rest content never lands
    # in clear text) and every registered PII column of the record's model.
    # The field name stays, so the row still says what changed.
    def redact_changes(record, changed_fields)
      return changed_fields if changed_fields.blank?

      hidden = redacted_audit_names(record)
      return changed_fields if hidden.empty?

      changed_fields.to_h { |field, change| [ field, hidden.include?(field.to_s) ? REDACTED : change ] }
    end

    # Request params stored in audit metadata. Rails' filter_parameters has
    # already run; this covers the registry's PII columns it doesn't name
    # (city, state, postal_code, country).
    def redact_params(params)
      @pii_param_names ||= names(sensitivity: :pii).to_set
      deep_redact(params, @pii_param_names)
    end

    private

    def redacted_audit_names(record)
      encrypted = Array(record.class.try(:encrypted_attributes)).map(&:to_s)
      pii = BY_MODEL.fetch(record.class.name, {}).values.select(&:pii?).map(&:name)
      (encrypted | pii).to_set
    end

    def deep_redact(value, hidden)
      case value
      when Hash
        value.to_h { |key, inner| [ key, hidden.include?(key.to_s) && !inner.nil? ? REDACTED : deep_redact(inner, hidden) ] }
      when Array
        value.map { |inner| deep_redact(inner, hidden) }
      else
        value
      end
    end

    def model_name_for(model)
      model.is_a?(Class) ? model.name : model.to_s
    end
  end
end
