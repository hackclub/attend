require "rails_helper"

RSpec.describe "Api::V1::Events", type: :request do
  let(:user) { User.create!(email: "events-api@example.com", name: "Staff") }
  let(:headers) { { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" } }

  def count_queries
    count = 0
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  # The mobile app hits this on launch, and it now resolves a role and a PII
  # capability per event. Both come from plucks memoized for the whole request,
  # and the logo/banner attachments are preloaded, so the cost must stay flat.
  it "costs the same number of queries however many events the user has" do
    4.times { |i| EventRoleAssignment.create!(user: user, event: create(:event), role: i.zero? ? "limited" : "ops") }
    get api_v1_events_path, headers: headers
    expect(response).to have_http_status(:ok)
    baseline = count_queries { get api_v1_events_path, headers: headers }

    8.times { EventRoleAssignment.create!(user: user, event: create(:event), role: "ops") }
    grown = count_queries { get api_v1_events_path, headers: headers }

    expect(JSON.parse(response.body)["events"].size).to eq(12)
    expect(grown).to eq(baseline)
  end

  describe "capability flags" do
    def event_payload(event)
      get api_v1_events_path, headers: headers
      JSON.parse(response.body)["events"].find { |e| e["id"] == event.id }
    end

    it "keeps read-only staff away from participants" do
      event = create(:event)
      EventRoleAssignment.create!(user: user, event: event, role: "read_only")

      expect(event_payload(event)).to include(
        "role" => "read_only",
        "can_view_participants" => false,
        "can_view_sensitive_data" => false
      )
    end

    it "lets limited staff see participants without PII or sensitive data" do
      event = create(:event)
      EventRoleAssignment.create!(user: user, event: event, role: "limited")

      expect(event_payload(event)).to include(
        "can_view_participants" => true,
        "can_view_participant_pii" => false,
        "can_view_sensitive_data" => false
      )
    end

    it "gives safeguarding leads sensitive data" do
      event = create(:event)
      EventRoleAssignment.create!(user: user, event: event, role: "safeguarding_lead")

      expect(event_payload(event)).to include(
        "can_view_participants" => true,
        "can_view_sensitive_data" => true
      )
    end

    it "reports whether the event runs travel" do
      with_travel = create(:event)
      without_travel = create(:event)
      without_travel.update!(travel_enabled: false)
      [ with_travel, without_travel ].each do |event|
        EventRoleAssignment.create!(user: user, event: event, role: "ops")
      end

      expect(event_payload(with_travel)["travel_enabled"]).to be(true)
      expect(event_payload(without_travel)["travel_enabled"]).to be(false)
    end
  end
end
