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
