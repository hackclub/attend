require "rails_helper"
require Rails.root.join("db/migrate/20261022130000_standardise_incident_levels")

RSpec.describe StandardiseIncidentLevels do
  let(:incident) { create(:incident, severity: "s2") }
  let(:migration) { described_class.new.tap { |m| m.verbose = false } }

  it "remaps PaperTrail versions so old snapshots still reify" do
    version = PaperTrail::Version.create!(item_type: "Incident", item_id: incident.id, event: "update",
      object: "id: #{incident.id}\nseverity: critical\nlocation: high street\n",
      object_changes: "severity:\n- low\n- high\nlocation:\n- low\n- critical\n")

    migration.send(:remap_versions, "Incident", "severity", described_class::SEVERITY)
    version.reload

    expect(version.object).to include("severity: s0", "location: high street")
    expect(version.object_changes).to include("severity:\n- s3\n- s1\n", "location:\n- low\n- critical\n")
    expect(version.reify.severity).to eq("s0")

    migration.send(:remap_versions, "Incident", "severity", described_class::SEVERITY.invert)
    expect(version.reload.object).to include("severity: critical")
  end
end
