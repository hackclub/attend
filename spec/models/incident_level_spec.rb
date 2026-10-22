require "rails_helper"

RSpec.describe IncidentLevel do
  it "is the scale both incident models use" do
    expect(Incident.severities.keys).to eq(described_class::KEYS)
    expect(IncidentReport::PRIORITIES.keys).to eq(described_class::KEYS)
  end

  it "keeps the emergency rules on S0" do
    event = create(:event, starts_at: 1.day.ago, ends_at: 1.day.from_now)
    report = build(:incident_report, event: event, priority: "s2", emergency_services_called: true)
    report.valid?
    expect(report.priority).to eq("s0")
    expect(report).to be_emergency

    old = create(:event, starts_at: 3.months.ago, ends_at: 2.months.ago)
    stale = build(:incident_report, event: old, priority: "s0")
    stale.valid?
    expect(stale.priority).to eq("s1")
  end

  it "labels levels with their code, name and response target" do
    expect(described_class.label("s0")).to eq("S0 · High priority · ≈ 5 minutes")
    expect(described_class.code("s3")).to eq("S3")
    expect(described_class.label("nope")).to eq("Nope")
  end
end
