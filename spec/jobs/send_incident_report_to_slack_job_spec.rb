require "rails_helper"

RSpec.describe SendIncidentReportToSlackJob do
  let(:report) { create(:incident_report, priority: "s1", summary: "Made-up summary") }

  it "builds a post that links to the report in the HQ inbox" do
    blocks = described_class.new.send(:build_blocks, report)
    text = blocks.to_json
    expect(text).to include("S1 · Moderate priority")
    expect(text).to include("/admin/incidents/#{report.id}")
  end
end
