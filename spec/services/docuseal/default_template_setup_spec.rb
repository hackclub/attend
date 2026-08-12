require "rails_helper"

RSpec.describe Docuseal::DefaultTemplateSetup do
  let(:event) { create(:event, name: "Test Summit", docuseal_host: "https://legacy.example.com") }
  let(:client) { instance_double(Docuseal::Client) }

  before do
    allow(Docuseal::HostConfig).to receive(:default_host).and_return("https://selfhosted.example.com")
    allow(Docuseal::Client).to receive(:new).and_return(client)
  end

  describe "#call" do
    context "with the standard waiver" do
      before do
        allow(client).to receive(:clone_template).and_return({ "id" => 4242 })
      end

      it "clones the blueprint on the default host when the event has no templates" do
        result = described_class.new(event).call("waiver")

        expect(result).to be_success
        expect(Docuseal::Client).to have_received(:new).with(host: "https://selfhosted.example.com")
        expect(client).to have_received(:clone_template).with(
          1,
          hash_including(
            name: "Test Summit - Waiver",
            folder_name: "Test Summit",
            external_id: "attend_event_#{event.id}_waiver"
          )
        )
        expect(event.reload.docuseal_waiver_template_id).to eq("4242")
        expect(event.docuseal_host).to eq("https://selfhosted.example.com")
      end

      it "applies the default field mappings and clears any stale snapshot" do
        described_class.new(event).call("waiver")

        config = event.reload.docuseal_field_mappings["waiver"]
        expect(config["template_snapshot"]).to be_nil
        expect(config["mappings"]).to eq(described_class::DEFAULT_MAPPINGS["waiver"])
      end

      it "stays on the event's existing host when another template is already configured" do
        event.update!(docuseal_freedom_waiver_template_id: "99")

        described_class.new(event).call("waiver")

        expect(Docuseal::Client).to have_received(:new).with(host: "https://legacy.example.com")
        expect(event.reload.docuseal_host).to eq("https://legacy.example.com")
      end
    end

    context "with the freedom waiver" do
      before do
        allow(client).to receive(:clone_template).and_return({ "id" => 777 })
      end

      it "also writes the default freedom checkbox config" do
        result = described_class.new(event).call("freedom_waiver")

        expect(result).to be_success
        expect(event.reload.docuseal_freedom_waiver_template_id).to eq("777")
        config = event.docuseal_field_mappings["freedom_waiver"]
        expect(config["freedom_checkbox_config"]).to eq(described_class::DEFAULT_FREEDOM_CHECKBOX_CONFIG)
      end
    end

    it "fails without calling DocuSeal for types with no blueprint" do
      result = described_class.new(event).call("adult_waiver")

      expect(result).not_to be_success
      expect(result.message).to include("No default template")
      expect(Docuseal::Client).not_to have_received(:new)
    end

    it "returns a failure result when DocuSeal errors" do
      allow(client).to receive(:clone_template).and_raise(Docuseal::Error, "boom")

      result = described_class.new(event).call("waiver")

      expect(result).not_to be_success
      expect(result.message).to include("boom")
      expect(event.reload.docuseal_waiver_template_id).to be_nil
    end
  end
end
