require "rails_helper"

RSpec.describe IncidentReportPolicy do
  let(:report) { create(:incident_report) }

  it "lets global admins in" do
    policy = described_class.new(build(:user, global_role: "global_admin"), report)
    expect(policy.index?).to be(true)
    expect(policy.show?).to be(true)
    expect(policy.comment?).to be(true)
    expect(policy.manage_settings?).to be(true)
  end

  it "keeps everyone else out, including the event's own organizers" do
    organizer = create(:user)
    EventRoleAssignment.create!(user: organizer, event: report.event, role: "event_admin")
    policy = described_class.new(organizer, report)
    expect(policy.index?).to be(false)
    expect(policy.show?).to be(false)
    expect(policy.comment?).to be(false)
    expect(described_class::Scope.new(organizer, IncidentReport).resolve).to be_empty
  end
end
