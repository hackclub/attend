require "rails_helper"

RSpec.describe TrainingStatus do
  let(:event) { create(:event) }
  let!(:everyone) { create(:training_badge, required_roles: %w[event_admin ops volunteer]) }
  let!(:leads) { create(:training_badge, required_roles: %w[safeguarding_lead]) }

  def state_for(user)
    TrainingStatus.for_event(event).for(user).state
  end

  it "flags staff without the badge their role requires" do
    ops = create(:event_role_assignment, event: event, role: "ops").user
    expect(state_for(ops)).to eq(:untrained)
  end

  it "counts a current award as trained" do
    ops = create(:event_role_assignment, event: event, role: "ops").user
    create(:training_badge_award, user: ops, badge: everyone)
    expect(state_for(ops)).to eq(:trained)
  end

  it "ignores revoked and expired awards" do
    ops = create(:event_role_assignment, event: event, role: "ops").user
    create(:training_badge_award, user: ops, badge: everyone, revoked_at: 1.day.ago)
    create(:training_badge_award, user: ops, badge: everyone, awarded_at: 2.years.ago, expires_at: 1.year.ago)

    result = TrainingStatus.for_event(event).for(ops)
    expect(result.state).to eq(:untrained)
    expect(result.lapsed).to eq([ everyone ])
  end

  it "warns when the only award runs out within the renewal window" do
    ops = create(:event_role_assignment, event: event, role: "ops").user
    create(:training_badge_award, user: ops, badge: everyone, awarded_at: 11.months.ago, expires_at: 10.days.from_now)
    expect(state_for(ops)).to eq(:expiring)
  end

  it "covers volunteers, and roles with no requirement" do
    volunteer = create(:event_volunteer, event: event).user
    read_only = create(:event_role_assignment, event: event, role: "read_only").user

    expect(state_for(volunteer)).to eq(:untrained)
    expect(state_for(read_only)).to eq(:not_required)
  end

  it "requires every badge any of a person's roles needs" do
    lead = create(:event_role_assignment, event: event, role: "safeguarding_lead").user
    create(:event_volunteer, event: event, user: lead)
    create(:training_badge_award, user: lead, badge: everyone)

    result = TrainingStatus.for_event(event).for(lead)
    expect(result.missing).to eq([ leads ])
    expect(TrainingStatus.for_event(event).summary).to include(required: 1, untrained: 1)
  end

  describe "a badge required of everyone working an event" do
    before { TrainingBadge.update_all(required_roles: []) }

    let!(:everyone_badge) { create(:training_badge, required_roles: [ TrainingBadge::EVERYONE, "ops" ]) }

    it "is stored as everyone alone, and covers every role and volunteers" do
      expect(everyone_badge.reload.required_roles).to eq([ TrainingBadge::EVERYONE ])

      read_only = create(:event_role_assignment, event: event, role: "read_only").user
      volunteer = create(:event_volunteer, event: event).user
      expect(state_for(read_only)).to eq(:untrained)
      expect(state_for(volunteer)).to eq(:untrained)
      expect(TrainingBadge.required_for("some_future_role")).to include(everyone_badge)
    end
  end

  describe "series owners and organizers" do
    let(:series) { create(:event_series) }
    let(:event) { create(:event, event_series: series) }

    it "count as event admins without a role on the event" do
      organizer = create(:user)
      SeriesRoleAssignment.create!(user: organizer, event_series: series, role: "organizer")

      expect(state_for(organizer)).to eq(:untrained)
      expect(TrainingStatus.for_user_at_event(organizer, event).missing).to eq([ everyone ])

      create(:training_badge_award, user: organizer, badge: everyone)
      expect(state_for(organizer)).to eq(:trained)
    end
  end
end
