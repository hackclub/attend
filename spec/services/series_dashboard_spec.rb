require "rails_helper"

RSpec.describe SeriesDashboard do
  let(:series) { create(:event_series, name: "Sunbeam", slug: "sunbeam-dashboard-spec") }
  let(:global_admin) { User.create!(email: "ga-dashboard@example.com", name: "GA", global_role: "global_admin") }

  def dashboard_for(events, user: global_admin)
    described_class.new(series, events: Array(events), user: user)
  end

  describe "the funnel" do
    let(:event) { create(:event, event_series: series, starts_at: 2.weeks.from_now) }

    it "reports nothing when the series has no participants" do
      dashboard = dashboard_for(event)

      expect(dashboard.totals[:active]).to eq(0)
      expect(dashboard.stage_rows).to be_empty
      expect(dashboard.chase_rows).to be_empty
    end

    # The claim the whole surface rests on: because a participant's blocking step
    # is the *first* one they haven't cleared, the drop between two bars is
    # exactly the number stalled on the lower one. If this ever stops holding,
    # the funnel and the chase list are telling two different stories.
    it "keeps cleared[n] == cleared[n-1] - stalled[n] at every stage" do
      6.times { create(:participant_event, event: event) }
      dashboard = dashboard_for(event)

      previous = dashboard.totals[:active]
      dashboard.stage_rows.each do |row|
        expect(row[:cleared]).to eq(previous - row[:stalled]),
          "#{row[:stage].key}: expected #{previous - row[:stalled]}, got #{row[:cleared]}"
        previous = row[:cleared]
      end
    end

    it "accounts for every active participant exactly once" do
      4.times { create(:participant_event, event: event) }
      dashboard = dashboard_for(event)

      stalled = dashboard.stage_rows.sum { |row| row[:stalled] }
      expect(stalled + dashboard.totals[:cleared]).to eq(dashboard.totals[:active])
    end

    # The reason this service reuses ParticipantEvent#onboarding_progress rather
    # than reimplementing it in SQL. A series total that disagrees with the rows
    # behind it is worse than a slower page.
    it "agrees with each participant's own onboarding_progress" do
      records = 5.times.map { create(:participant_event, event: event) }
      dashboard = dashboard_for(event)

      per_record_cleared = records.count { |pe| pe.reload.onboarding_progress[:blocking_step].nil? }
      expect(dashboard.totals[:cleared]).to eq(per_record_cleared)

      expected_stalled = records.group_by { |pe|
        described_class::STEP_TO_STAGE[pe.reload.onboarding_progress[:blocking_step]]
      }.transform_values(&:size)

      dashboard.stage_rows.each do |row|
        expect(row[:stalled]).to eq(expected_stalled.fetch(row[:stage].key, 0)),
          "#{row[:stage].key} disagreed with the per-record blocking step"
      end
    end

    it "leaves withdrawn and rejected participants out of the funnel" do
      create(:participant_event, event: event)
      create(:participant_event, event: event, status: :withdrawn)
      create(:participant_event, event: event, status: :rejected)

      dashboard = dashboard_for(event)

      expect(dashboard.totals[:active]).to eq(1)
      expect(dashboard.totals[:inactive]).to eq(2)
    end

    it "names the biggest blocker on each event" do
      3.times { create(:participant_event, event: event) }
      row = dashboard_for(event).event_rows.first

      expect(row[:top_blocker][:count]).to eq(3)
      expect(row[:top_blocker][:stage].key).to eq(:profile).or eq(:travel)
    end
  end

  describe "check-in" do
    it "is not measured for an event that hasn't started" do
      event = create(:event, event_series: series, starts_at: 3.days.from_now)
      create(:participant_event, event: event)

      expect(dashboard_for(event).arrival_row).to be_nil
    end

    it "counts only participants whose event has started and records check-ins" do
      event = create(:event, event_series: series, starts_at: 2.days.ago, ends_at: 1.day.from_now)
      future = create(:event, event_series: series, starts_at: 3.days.from_now)
      create(:participant_event, event: future)

      # Cleared onboarding is a precondition for arriving, so an unfinished
      # participant must not appear in the arrival denominator either.
      create(:participant_event, event: event)

      row = dashboard_for([ event, future ]).arrival_row
      expect(row).to be_nil
    end
  end

  describe "incidents" do
    let(:event) { create(:event, event_series: series) }

    before do
      Incident.create!(
        event: event, reported_by: global_admin, category: "safeguarding",
        severity: "low", status: "open", visible_to_roles: [ "safeguarding_lead" ]
      )
    end

    it "counts every open incident for a global admin" do
      expect(dashboard_for(event).open_incidents[event.id]).to eq(1)
    end

    # Series membership alone does not grant incident visibility — IncidentPolicy
    # keys off event_role_assignments — so this must stay nil rather than 0, or
    # the view would report "none open" to someone who simply cannot see them.
    it "returns nil for a series member with no event role" do
      member = User.create!(email: "member-dashboard@example.com", name: "Member")
      SeriesRoleAssignment.create!(user: member, event_series: series, role: "organizer")

      expect(dashboard_for(event, user: member).open_incidents[event.id]).to be_nil
    end

    it "respects an incident's visible_to_roles for a user with an event role" do
      ops = User.create!(email: "ops-dashboard@example.com", name: "Ops")
      EventRoleAssignment.create!(user: ops, event: event, role: "ops")

      expect(dashboard_for(event, user: ops).open_incidents[event.id]).to eq(0)
    end
  end

  describe "totals" do
    it "reports how many active participants are still blocked" do
      event = create(:event, event_series: series, starts_at: 2.weeks.from_now)
      3.times { create(:participant_event, event: event) }
      create(:participant_event, event: event, status: :withdrawn)

      totals = dashboard_for(event).totals

      expect(totals[:blocked]).to eq(totals[:active] - totals[:cleared])
      expect(totals[:blocked]).to eq(3)
    end
  end

  # Ordering by starts_at alone buries the event that is running right now under
  # every future one, which is the last thing the person opening this page wants.
  describe ".order_events" do
    it "puts live events first, then upcoming, then undated drafts, then the past" do
      live = create(:event, event_series: series, name: "Live", starts_at: 1.day.ago, ends_at: 2.days.from_now)
      upcoming = create(:event, event_series: series, name: "Upcoming", starts_at: 3.days.from_now, ends_at: 5.days.from_now)
      undated = create(:event, event_series: series, name: "Undated", starts_at: nil, ends_at: nil)
      past = create(:event, event_series: series, name: "Past", starts_at: 3.weeks.ago, ends_at: 2.weeks.ago)

      ordered = described_class.order_events([ past, upcoming, undated, live ])

      expect(ordered).to eq([ live, upcoming, undated, past ])
    end

    it "orders upcoming events soonest-first and past events most-recent-first" do
      soon = create(:event, event_series: series, starts_at: 2.days.from_now, ends_at: 3.days.from_now)
      later = create(:event, event_series: series, starts_at: 2.weeks.from_now, ends_at: 3.weeks.from_now)
      recent = create(:event, event_series: series, starts_at: 2.weeks.ago, ends_at: 13.days.ago)
      ancient = create(:event, event_series: series, starts_at: 1.year.ago, ends_at: 1.year.ago + 1.day)

      ordered = described_class.order_events([ ancient, later, recent, soon ])

      expect(ordered).to eq([ soon, later, recent, ancient ])
    end
  end

  describe "the map" do
    it "separates events with a venue location from those without" do
      located = create(:event, event_series: series)
      # No city either: setting the city is what triggers Event#geocode_location,
      # which would put the coordinates straight back.
      unlocated = create(:event, event_series: series, location_city: nil,
                                 location_country: nil, location_latitude: nil,
                                 location_longitude: nil)

      dashboard = dashboard_for([ located, unlocated ])

      expect(dashboard.mappable_events).to eq([ located ])
      expect(dashboard.unmapped_events).to eq([ unlocated ])
    end
  end
end
