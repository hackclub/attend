require "rails_helper"

RSpec.describe SensitiveFields do
  it "classifies registered columns by model" do
    expect(described_class.sensitivity(Participant, :date_of_birth)).to eq(:pii)
    expect(described_class.sensitivity("Medical", "allergies")).to eq(:medical)
    expect(described_class.sensitivity(SafeguardingInfo, :high_support_notes)).to eq(:safeguarding)
    expect(described_class.sensitivity(Participant, :tshirt_size)).to be_nil
    # `state` is an address on a person and nothing of the sort elsewhere.
    expect(described_class.pii?(Guardian, :state)).to be(true)
    expect(described_class.pii?(Event, :state)).to be(false)
  end

  it "only names columns that exist" do
    missing = described_class::COLUMNS.reject { |field| field.model.constantize.column_names.include?(field.name) }

    expect(missing.map { |field| "#{field.model}##{field.name}" }).to be_empty
  end

  # The four lists that used to be written out by hand now read from the
  # registry. These pin them to exactly what they were, so the registry can
  # grow without quietly changing what a surface shows.
  describe "the lists derived from it" do
    it "keeps the version-history PII and email lists as they were" do
      expect(Admin::AuditLogsHelper::PII_FIELDS).to match_array(%w[
        date_of_birth address_line_1 address_line_2 city state postal_code
        country country_of_residence
        phone phone_number phone_override
      ])
      expect(Admin::AuditLogsHelper::EMAIL_FIELDS).to match_array(%w[email invited_via_email])
    end

    it "keeps the anonymized MCP response lists as they were" do
      expect(Mcp::ResponseFilter::NAME_KEYS).to eq(%w[
        legal_name full_name preferred_name display_name participant_name
        guardian_name author sent_by reported_by last_updated_by assigned_to
        closed_by created_by from staff_names roommate_name occupant_name
        emergency_contact_name next_of_kin
      ].to_set)
      expect(Mcp::ResponseFilter::REDACTED_KEYS).to eq(%w[
        email emails email_address personal_email work_email guardian_email
        phone phone_number phone_numbers mobile mobile_number home_phone
        twilio_to_number from_number to_number guardian_phone
        emergency_contact_phone emergency_contact emergency_contacts
        slack_user_id slack_id discord_id
        date_of_birth dob
        address street_address address_line1 address_line2 mailing_address
        postal_code postcode zip zipcode city state
        passport_number national_id ip_address
      ].to_set)
    end

    it "hides from PII-restricted roles what the API and MCP serializers always hid" do
      expect(described_class.restricted_names(Participant))
        .to match_array(%w[date_of_birth address_line_1 address_line_2 city state postal_code country_of_residence phone])
      expect(described_class.restricted_names(Guardian)).to include("email", "phone")
      expect(described_class.restricted_names(GuardianParticipantEvent)).to match_array(%w[phone_override invited_via_email])
      expect(described_class.restricted_names(Travel)).to eq(%w[origin_address])
      # A restricted role keeps an emergency contact's number and loses the rest.
      expect(described_class.restricted_names(EmergencyContact)).to match_array(%w[name email relationship])
    end
  end

  describe ".visible" do
    let(:attributes) { { email: "sam@example.com", phone: "+12025550111", tshirt_size: "M" } }

    it "passes everything through for a caller who may see PII" do
      expect(described_class.visible(Participant, attributes, pii: true)).to eq(attributes)
    end

    it "drops restricted PII, and nothing else, for one who may not" do
      # A participant's own email is the one PII field a restricted role keeps.
      expect(described_class.visible(Participant, attributes, pii: false))
        .to eq(email: "sam@example.com", tshirt_size: "M")
      expect(described_class.visible(Guardian, attributes, pii: false)).to eq(tshirt_size: "M")
    end
  end

  describe ".redact_changes" do
    it "redacts registered PII and encrypted attributes, keeping the field names" do
      guardian = build(:guardian)
      changes = {
        "email" => [ "old@example.com", "new@example.com" ],
        "city" => [ "Springfield", "Shelbyville" ],
        "phone" => [ "+12025550111", "+12025550112" ],
        "legal_first_name" => %w[Jane Janet]
      }

      expect(described_class.redact_changes(guardian, changes)).to eq(
        "email" => "[REDACTED]",
        "city" => "[REDACTED]",
        "phone" => "[REDACTED]",
        "legal_first_name" => %w[Jane Janet]
      )
    end

    it "leaves a model with nothing registered alone" do
      changes = { "name" => [ "Old Name", "New Name" ], "state" => %w[draft live] }

      expect(described_class.redact_changes(build(:event), changes)).to eq(changes)
    end
  end

  describe ".redact_params" do
    it "redacts a model's PII columns under that model's key" do
      params = { "guardian" => { "city" => "Springfield", "postal_code" => "05001", "legal_first_name" => "[FILTERED]" }, "id" => "abc" }

      expect(described_class.redact_params(params)).to eq(
        "guardian" => { "city" => "[REDACTED]", "postal_code" => "[REDACTED]", "legal_first_name" => "[FILTERED]" },
        "id" => "abc"
      )
    end

    it "follows Rails' nested-attributes keys, through the index hashes" do
      params = { "participant" => { "tshirt_size" => "L",
                                    "guardians_attributes" => { "0" => { "country" => "US", "id" => "abc" } } } }

      expect(described_class.redact_params(params)).to eq(
        "participant" => { "tshirt_size" => "L",
                           "guardians_attributes" => { "0" => { "country" => "[REDACTED]", "id" => "abc" } } }
      )
    end

    # `state` and `country` are PII on a person and plain data elsewhere.
    it "leaves the same key names alone where they aren't that model's column" do
      params = { "state" => "pending", "event" => { "country" => "US", "city" => "Burlington" },
                 "filters" => { "state" => "draft" } }

      expect(described_class.redact_params(params)).to eq(params)
      expect(described_class.redact_params(params, model: Event)).to eq(params)
    end

    it "reads top-level keys as the audited record's columns" do
      expect(described_class.redact_params({ "city" => "Springfield", "page" => "2" }, model: Guardian))
        .to eq("city" => "[REDACTED]", "page" => "2")
    end

    it "keeps the shape of a nested value under a PII key, without its contents" do
      params = { "guardian" => { "city" => { "name" => "Springfield", "codes" => %w[05001 05002], "none" => nil } } }

      expect(described_class.redact_params(params)).to eq(
        "guardian" => { "city" => { "name" => "[REDACTED]", "codes" => %w[[REDACTED] [REDACTED]], "none" => nil } }
      )
    end
  end
end
