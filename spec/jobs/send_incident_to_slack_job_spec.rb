require "rails_helper"

RSpec.describe SendIncidentToSlackJob do
  let(:event) { create(:event, timezone: "Eastern Time (US & Canada)") }

  def post_text(incident)
    described_class.new.send(:build_slack_blocks, incident, incident.reported_by).to_json
  end

  it "gives when it happened on the event's clock" do
    incident = create(:incident, event: event, occurred_at: "2026-07-12T09:30")

    expect(post_text(incident)).to include("July 12, 2026 at 09:30")
  end

  it "keeps a legacy row's time on UTC" do
    incident = create(:incident, event: event)
    incident.update_columns(occurred_at: Time.utc(2026, 7, 12, 9, 30), times_in_event_zone: false)

    expect(post_text(incident.reload)).to include("July 12, 2026 at 09:30")
  end
end
