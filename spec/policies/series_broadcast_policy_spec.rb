require "rails_helper"

RSpec.describe SeriesBroadcastPolicy do
  let(:series) { create(:event_series) }
  let(:other_series) { create(:event_series) }
  let(:event) { create(:event, event_series: series) }
  let(:broadcast) { SeriesBroadcast.new(event_series: series) }

  def user_with(series_role: nil, event_role: nil, global_role: nil, on: series)
    create(:user, **{ global_role: global_role }.compact).tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: on, role: series_role) if series_role
      create(:event_role_assignment, user: user, event: event, role: event_role) if event_role
    end
  end

  let(:actions) { %i[index? show? create? new? update? edit? destroy? preview? send_now? cancel?] }

  it "lets series owners do everything" do
    policy = described_class.new(user_with(series_role: "owner"), broadcast)
    expect(actions.map { |action| policy.public_send(action) }).to all(be(true))
  end

  it "lets global admins do everything" do
    policy = described_class.new(user_with(global_role: "global_admin"), broadcast)
    expect(actions.map { |action| policy.public_send(action) }).to all(be(true))
  end

  it "keeps series organizers out: they message each event from its own page" do
    policy = described_class.new(user_with(series_role: "organizer"), broadcast)
    expect(actions.map { |action| policy.public_send(action) }).to all(be(false))
  end

  it "keeps event-level roles out, even an event admin on one of the series' events" do
    %w[event_admin ops].each do |role|
      policy = described_class.new(user_with(event_role: role), broadcast)
      expect(actions.map { |action| policy.public_send(action) }).to all(be(false))
    end
  end

  it "keeps out the owner of a different series" do
    policy = described_class.new(user_with(series_role: "owner", on: other_series), broadcast)
    expect(actions.map { |action| policy.public_send(action) }).to all(be(false))
  end
end
