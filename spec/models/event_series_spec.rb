require "rails_helper"

RSpec.describe EventSeries, type: :model do
  it "has a valid factory" do
    expect(build(:event_series)).to be_valid
  end

  it "requires a name" do
    expect(build(:event_series, name: nil, slug: "has-a-slug")).not_to be_valid
  end

  it "generates a slug from the name" do
    series = create(:event_series, name: "Sunbeam Series!", slug: nil)
    expect(series.slug).to eq("sunbeam-series")
  end

  it "rejects invalid slugs" do
    expect(build(:event_series, slug: "Has Spaces")).not_to be_valid
    expect(build(:event_series, slug: "new")).not_to be_valid
  end

  it "enforces slug uniqueness" do
    create(:event_series, slug: "dupe-series")
    expect(build(:event_series, slug: "dupe-series")).not_to be_valid
  end

  it "nullifies events when destroyed" do
    series = create(:event_series)
    event = create(:event, event_series: series)

    series.destroy!

    expect(event.reload.event_series_id).to be_nil
  end

  describe "membership uniqueness" do
    it "allows one role per user per series" do
      assignment = create(:series_role_assignment)
      dupe = build(:series_role_assignment, user: assignment.user, event_series: assignment.event_series, role: "owner")

      expect(dupe).not_to be_valid
    end
  end

  describe "branding fallback" do
    let(:svg) { "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'><rect width='10' height='10' fill='red'/></svg>" }

    it "events without a logo inherit the series logo" do
      series = create(:event_series)
      series.logo.attach(io: StringIO.new(svg), filename: "s.svg", content_type: "image/svg+xml")
      series.save!
      event = create(:event, event_series: series)

      expect(event.effective_logo).to eq(series.logo)
    end

    it "events with their own logo keep it" do
      series = create(:event_series)
      series.logo.attach(io: StringIO.new(svg), filename: "s.svg", content_type: "image/svg+xml")
      series.save!
      event = create(:event, event_series: series)
      event.logo.attach(io: StringIO.new(svg), filename: "e.svg", content_type: "image/svg+xml")
      event.save!

      expect(event.effective_logo).to eq(event.logo)
    end

    it "returns nil when neither has a logo" do
      event = create(:event, event_series: create(:event_series))
      expect(event.effective_logo).to be_nil
    end
  end

  describe "contact email" do
    it "rejects malformed addresses" do
      expect(build(:event_series, contact_email: "not-an-email")).not_to be_valid
      expect(build(:event_series, contact_email: "sunbeam@hackclub.com")).to be_valid
      expect(build(:event_series, contact_email: "")).to be_valid
    end
  end

  describe "Event#effective_support_email" do
    let(:series) { create(:event_series, contact_email: "series@hackclub.com") }

    it "prefers the event's own support email" do
      event = create(:event, event_series: series, support_email: "own@hackclub.com")
      expect(event.effective_support_email).to eq("own@hackclub.com")
    end

    it "falls back to the series contact email" do
      event = create(:event, event_series: series, support_email: nil)
      expect(event.effective_support_email).to eq("series@hackclub.com")
    end

    it "defaults to team@hackclub.com when neither is set" do
      event = create(:event, support_email: nil)
      expect(event.effective_support_email).to eq("team@hackclub.com")
    end
  end

  describe "support inbox access" do
    let(:series) { create(:event_series) }
    let!(:live_sub_event) { create(:event, event_series: series, starts_at: 1.week.from_now, ends_at: 2.weeks.from_now) }
    let(:member) { create(:series_role_assignment, event_series: series).user }

    it "counts series events as support-staffed events" do
      expect(member.support_staff_event_ids).to include(live_sub_event.id)
    end

    it "grants triage access while a series event is within its support window" do
      expect(member.support_inbox_triage_access?).to be(true)
    end

    it "denies triage access when all series events are long past" do
      live_sub_event.update!(
        starts_at: 6.weeks.ago, ends_at: 5.weeks.ago,
        registration_open_at: 8.weeks.ago, registration_close_at: 7.weeks.ago
      )
      expect(member.support_inbox_triage_access?).to be(false)
    end
  end
end
