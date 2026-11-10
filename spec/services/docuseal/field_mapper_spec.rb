require "rails_helper"

RSpec.describe Docuseal::FieldMapper do
  let(:event) { create(:event) }
  let(:participant) { create(:participant, legal_first_name: "Jane", legal_last_name: "Doe") }
  let(:guardian) { create(:guardian, legal_first_name: "John", legal_last_name: "Smith") }

  describe "#has_mappings?" do
    context "when no mappings configured" do
      it "returns false" do
        mapper = described_class.new(event: event, template_type: "waiver")
        expect(mapper.has_mappings?).to be false
      end
    end

    context "when mappings are configured" do
      before do
        event.update!(docuseal_field_mappings: {
          "waiver" => {
            "mappings" => [
              { "field_name" => "Attendee Name", "source_key" => "participant.full_name", "readonly" => true }
            ]
          }
        })
      end

      it "returns true" do
        mapper = described_class.new(event: event, template_type: "waiver")
        expect(mapper.has_mappings?).to be true
      end
    end
  end

  describe "#build_fields_for_role" do
    let(:context) do
      {
        participant: participant,
        guardian: guardian,
        emergency_contacts: [],
        event: event
      }
    end

    context "with configured mappings" do
      before do
        event.update!(docuseal_field_mappings: {
          "waiver" => {
            "mappings" => [
              { "field_name" => "Attendee Name", "source_key" => "participant.full_name", "readonly" => true, "role" => "Attendee" },
              { "field_name" => "Guardian Name", "source_key" => "guardian.full_name", "readonly" => true, "role" => "Guardian" }
            ]
          }
        })
      end

      it "builds fields for the attendee role" do
        mapper = described_class.new(event: event, template_type: "waiver")
        fields = mapper.build_fields_for_role(role: "Attendee", context: context)

        expect(fields).to contain_exactly(
          { name: "Attendee Name", default_value: "Jane Doe", readonly: true }
        )
      end

      it "builds fields for the guardian role" do
        mapper = described_class.new(event: event, template_type: "waiver")
        fields = mapper.build_fields_for_role(role: "Guardian", context: context)

        expect(fields).to contain_exactly(
          { name: "Guardian Name", default_value: "John Smith", readonly: true }
        )
      end
    end
  end

  context "when a template repeats a field name within one role" do
    let(:context) { { participant: participant, guardian: guardian, emergency_contacts: [], event: event } }
    let(:snapshot) do
      {
        "submitters" => [ { "name" => "First Party", "uuid" => "role-1" }, { "name" => "Second Party", "uuid" => "role-2" } ],
        "fields" => [
          { "name" => "Full Name", "uuid" => "name-page-1", "submitter_uuid" => "role-1" },
          { "name" => "Date of Birth", "uuid" => "dob", "submitter_uuid" => "role-1" },
          { "name" => "Full Name", "uuid" => "name-page-2", "submitter_uuid" => "role-1" },
          { "name" => "Full Name", "uuid" => "guardian-name", "submitter_uuid" => "role-2" }
        ]
      }
    end
    let(:template) { { "fields" => snapshot["fields"] } }

    def configure(mappings)
      event.update!(docuseal_field_mappings: {
        "custom_1" => { "mappings" => mappings, "template_snapshot" => snapshot }
      })
      described_class.new(event: event, template_type: "custom_1")
    end

    it "targets each mapping at its own field by uuid" do
      mapper = configure([
        { "field_name" => "Full Name", "field_uuid" => "name-page-1", "source_key" => "participant.full_name", "readonly" => true, "role" => "First Party" },
        { "field_name" => "Full Name", "field_uuid" => "name-page-2", "source_key" => "guardian.full_name", "readonly" => true, "role" => "First Party" }
      ])

      expect(mapper.build_fields_for_role(role: "First Party", context: context, template: template)).to eq([
        { uuid: "name-page-1", default_value: "Jane Doe", readonly: true },
        { uuid: "name-page-2", default_value: "John Smith", readonly: true }
      ])
    end

    it "pairs legacy name-only mappings with their fields in template order" do
      mapper = configure([
        { "field_name" => "Full Name", "source_key" => "participant.full_name", "readonly" => true, "role" => "First Party" },
        { "field_name" => "Date of Birth", "source_key" => "participant.date_of_birth", "readonly" => true, "role" => "First Party" },
        { "field_name" => "Full Name", "source_key" => "guardian.full_name", "readonly" => true, "role" => "First Party" }
      ])

      fields = mapper.build_fields_for_role(role: "First Party", context: context, template: template)

      expect(fields.map { |f| [ f[:uuid], f[:default_value] ] }).to eq([
        [ "name-page-1", "Jane Doe" ],
        [ "dob", participant.date_of_birth.strftime("%Y-%m-%d") ],
        [ "name-page-2", "John Smith" ]
      ])
    end

    it "never sends two conflicting values for one ambiguous name" do
      snapshot["fields"] << { "name" => "Full Name", "uuid" => "name-page-3", "submitter_uuid" => "role-1" }
      mapper = configure([
        { "field_name" => "Full Name", "source_key" => "participant.full_name", "readonly" => true, "role" => "First Party" },
        { "field_name" => "Full Name", "source_key" => "guardian.full_name", "readonly" => true, "role" => "First Party" }
      ])

      expect(mapper.build_fields_for_role(role: "First Party", context: context)).to eq([
        { name: "Full Name", default_value: "Jane Doe", readonly: true }
      ])
    end

    it "falls back to the field name when the live template no longer has the uuid" do
      mapper = configure([
        { "field_name" => "Full Name", "field_uuid" => "deleted-field", "source_key" => "guardian.full_name", "readonly" => true, "role" => "Second Party" }
      ])

      expect(mapper.build_fields_for_role(role: "Second Party", context: context, template: template)).to eq([
        { name: "Full Name", default_value: "John Smith", readonly: true }
      ])
    end

    it "finds each row's own mapping for the mappings page" do
      mapper = configure([
        { "field_name" => "Full Name", "field_uuid" => "name-page-2", "source_key" => "guardian.full_name", "role" => "First Party" },
        { "field_name" => "Full Name", "field_uuid" => "guardian-name", "source_key" => "guardian.email", "role" => "Second Party" }
      ])

      expect(mapper.mapping_for_field(snapshot["fields"][0])).to be_nil
      expect(mapper.mapping_for_field(snapshot["fields"][2])["source_key"]).to eq("guardian.full_name")
      expect(mapper.mapping_for_field(snapshot["fields"][3])["source_key"]).to eq("guardian.email")
    end
  end

  describe "#freedom_checkbox_config" do
    context "when configured" do
      before do
        event.update!(docuseal_field_mappings: {
          "freedom_waiver" => {
            "freedom_checkbox_config" => {
              "granted_field" => "I Grant Permission",
              "rejected_field" => "I Reject Permission"
            }
          }
        })
      end

      it "returns the configured checkbox fields" do
        mapper = described_class.new(event: event, template_type: "freedom_waiver")
        config = mapper.freedom_checkbox_config

        expect(config["granted_field"]).to eq("I Grant Permission")
        expect(config["rejected_field"]).to eq("I Reject Permission")
      end
    end

    context "when not configured" do
      it "returns empty hash" do
        mapper = described_class.new(event: event, template_type: "freedom_waiver")
        expect(mapper.freedom_checkbox_config).to eq({})
      end
    end
  end
end
