require "rails_helper"

RSpec.describe RegistrationCorrectionNotifications do
  include ActiveJob::TestHelper

  it "notifies inherited series event admins once each" do
    series = create(:event_series)
    event = create(:event, event_series: series)
    participant_event = create(:participant_event, event: event)
    owner = create(:user, email: "series-owner@example.com")
    organizer = create(:user, email: "series-organizer@example.com")
    duplicate_admin = create(:user, email: "duplicate-admin@example.com")
    create(:series_role_assignment, :owner, event_series: series, user: owner)
    create(:series_role_assignment, event_series: series, user: organizer, role: :organizer)
    create(:series_role_assignment, event_series: series, user: duplicate_admin, role: :organizer)
    create(:event_role_assignment, event: event, user: duplicate_admin, role: :event_admin)

    perform_enqueued_jobs do
      described_class.direct_update(participant_event, section: :contact)
    end

    recipients = ActionMailer::Base.deliveries.last(3).map(&:to)
    expect(recipients).to contain_exactly(
      [ "series-owner@example.com" ],
      [ "series-organizer@example.com" ],
      [ "duplicate-admin@example.com" ]
    )
  end
end
