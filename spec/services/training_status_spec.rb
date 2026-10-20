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
end
