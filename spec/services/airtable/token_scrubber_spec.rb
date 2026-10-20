require "rails_helper"

RSpec.describe Airtable::TokenScrubber do
  it "redacts the token from a version's YAML, where config is a JSON string" do
    yaml = <<~YAML
      ---
      config:
      - '{"travel_enabled":"1","airtable_api_key":"patFictional.abc123","airtable_base_id":"appX"}'
      - '{"travel_enabled":"1","airtable_api_key":"patFictional.def456","airtable_base_id":"appX"}'
    YAML

    scrubbed = described_class.scrub_text(yaml)

    expect(scrubbed).not_to include("patFictional")
    expect(scrubbed.scan('"airtable_api_key":"[REDACTED]"').size).to eq(2)
    expect(scrubbed).to include('"airtable_base_id":"appX"')
    expect(YAML.safe_load(scrubbed)["config"].first).to include("[REDACTED]")
  end

  it "redacts a YAML mapping and leaves blank values alone" do
    expect(described_class.scrub_text("  airtable_api_key: patFictional\n")).to eq(%(  airtable_api_key: "[REDACTED]"\n))
    expect(described_class.scrub_text(%({"airtable_api_key":""}))).to eq(%({"airtable_api_key":""}))
  end

  it "redacts the token anywhere in an audit log's jsonb" do
    changed_fields = {
      "config" => [
        { "airtable_api_key" => "patFictional.old", "travel_enabled" => "1" },
        { "airtable_api_key" => "patFictional.new", "travel_enabled" => "1" }
      ]
    }

    expect(described_class.scrub_value(changed_fields)).to eq(
      "config" => [
        { "airtable_api_key" => "[REDACTED]", "travel_enabled" => "1" },
        { "airtable_api_key" => "[REDACTED]", "travel_enabled" => "1" }
      ]
    )
  end

  it "is idempotent" do
    once = described_class.scrub_text(%({"airtable_api_key":"patFictional"}))

    expect(described_class.scrub_text(once)).to eq(once)
  end
end
