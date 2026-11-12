require "rails_helper"

# The invite form used to check only for a *pending* invitation, so once
# someone had accepted theirs and registered, staff could mint them a second
# one: it emailed them a link to a wizard they'd already finished and put them
# back on the pending invitations tab.
RSpec.describe "Inviting someone already registered", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:participant) { create(:participant, email: "Quill.Marsh@example.com") }

  before do
    user = User.create!(email: "event-admin-reinvite@example.com", name: "Event Admin")
    EventRoleAssignment.create!(user: user, event: event, role: "event_admin")
    sign_in user
  end

  %i[in_progress awaiting_guardian complete].each do |status|
    it "refuses a #{status} registration without minting or emailing an invitation" do
      create(:participant_event, participant: participant, event: event, status: status)

      expect {
        post send_invite_admin_event_participants_path(event.slug),
          params: { invite: { email: "quill.marsh@example.com" } }
      }.to not_change(Invitation, :count).and not_have_enqueued_job(ActionMailer::Base.delivery_job)

      expect(response).to redirect_to(new_invite_admin_event_participants_path(event))
      expect(flash[:alert]).to eq("quill.marsh@example.com is already registered for this event.")
    end
  end

  it "still resends to an imported registration that hasn't started" do
    create(:participant_event, participant: participant, event: event, status: :invited)
    create(:invitation, event: event, email: "quill.marsh@example.com", sent_at: 1.day.ago)

    expect {
      post send_invite_admin_event_participants_path(event.slug),
        params: { invite: { email: "quill.marsh@example.com", send_now: "1" } }
    }.to have_enqueued_mail(ParticipantMailer, :invitation)
  end
end
