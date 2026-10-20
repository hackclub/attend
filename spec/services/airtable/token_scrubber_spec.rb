require "rails_helper"

RSpec.describe Airtable::TokenScrubber do
  # What PaperTrail writes for an Event: config is jsonb, so it arrives as a
  # JSON string inside the YAML.
  def serialized_config_change(old_key, new_key)
    PaperTrail.serializer.dump(
      "config" => [
        { "travel_enabled" => "1", "airtable_api_key" => old_key, "airtable_base_id" => "appX" }.to_json,
        { "travel_enabled" => "1", "airtable_api_key" => new_key, "airtable_base_id" => "appX" }.to_json
      ]
    )
  end

  it "redacts tokens from a version, leaving the other config intact" do
    text = serialized_config_change("patFictional.abc123", "patFictional.def456")

    scrubbed = described_class.scrub_serialized(text)
    config = PaperTrail.serializer.load(scrubbed)["config"].map { |json| JSON.parse(json) }

    expect(scrubbed).not_to include("patFictional")
    expect(config.pluck("airtable_api_key")).to eq([ "[REDACTED]", "[REDACTED]" ])
    expect(config.pluck("airtable_base_id")).to eq(%w[appX appX])
    expect(described_class.serialized_leaks?(scrubbed)).to be(false)
  end

  # Regex scrubbing missed these; parsing doesn't care how the YAML quotes.
  it "catches tokens however the YAML was quoted or folded" do
    long = "patFictional.#{'x' * 200} with 'quotes' and \"escapes\""
    text = PaperTrail.serializer.dump("config" => { "airtable_api_key" => long }, "name" => "Fictional")

    expect(described_class.serialized_leaks?(text)).to be(true)
    expect(described_class.scrub_serialized(text)).not_to include("patFictional")
  end

  it "leaves a version with only blank tokens untouched" do
    text = serialized_config_change("", "")

    expect(described_class.scrub_serialized(text)).to equal(text)
  end

  it "refuses to treat unparseable YAML as clean" do
    expect { described_class.scrub_serialized("config: [unclosed") }.to raise_error(Psych::SyntaxError)
  end

  it "redacts the token anywhere in an audit log's jsonb" do
    changed_fields = {
      "config" => [
        { "airtable_api_key" => "patFictional.old", "travel_enabled" => "1" },
        { "airtable_api_key" => "patFictional.new", "travel_enabled" => "1" }
      ]
    }

    scrubbed = described_class.scrub_value(changed_fields)

    expect(scrubbed["config"].pluck("airtable_api_key")).to eq([ "[REDACTED]", "[REDACTED]" ])
    expect(described_class.leaks?(scrubbed)).to be(false)
  end

  it "is idempotent" do
    once = described_class.scrub_serialized(serialized_config_change("patFictional", "patFictional"))

    expect(described_class.scrub_serialized(once)).to equal(once)
  end

  describe "rails airtable:scrub_leaked_tokens" do
    before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("airtable:scrub_leaked_tokens") }

    it "scrubs config, versions and audit logs, then verifies" do
      event = create(:event)
      event.update_columns(config: event.config.merge("airtable_api_key" => "patFictionalLeak"))
      version = PaperTrail::Version.create!(item: event, event: "update",
        object_changes: serialized_config_change("patFictionalLeak", "patFictionalLeak"))
      log = AuditLog.log!(action: "update_integrations", record: event, event: event,
        changed_fields: { "config" => [ {}, { "airtable_api_key" => "patFictionalLeak" } ] })

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("APPLY").and_return("1")

      expect { Rake::Task["airtable:scrub_leaked_tokens"].execute }.to output(/verified nothing is left/).to_stdout

      expect(event.reload.config).not_to have_key("airtable_api_key")
      expect(event.airtable_api_key).to eq("patFictionalLeak")
      expect(version.reload.object_changes).not_to include("patFictionalLeak")
      expect(log.reload.changed_fields.to_s).not_to include("patFictionalLeak")
    end
  end
end
