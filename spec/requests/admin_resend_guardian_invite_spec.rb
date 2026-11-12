require "rails_helper"

RSpec.describe "Admin resend guardian invite", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }
  let(:gpe) { create(:guardian_participant_event, participant_event: participant_event) }
  let(:admin) { User.create!(email: "admin-resend@example.com", name: "Admin", global_role: "global_admin") }

  before { sign_in admin }

  def resend!
    post resend_guardian_invite_admin_event_participant_path(event, participant_event),
      params: { guardian_participant_event_id: gpe.id }
  end

  it "kills the old portal link immediately, before the new email goes out" do
    old_token = gpe.generate_invite_token!
    gpe.update!(invite_token_sent_at: 1.day.ago, invite_last_used_at: 1.hour.ago)

    # Warm-up GET: the first POST after sign-in otherwise audit-logs the user.
    get admin_event_participant_path(event, participant_event)
    resend!

    expect(response).to redirect_to(admin_event_participant_path(event, participant_event))
    expect { GuardianParticipantEvent.find_by_invite_token!(old_token) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  it "emails a new link that works while the old one stays dead" do
    old_token = gpe.generate_invite_token!
    gpe.update!(invite_token_sent_at: 1.day.ago)

    get admin_event_participant_path(event, participant_event)
    perform_enqueued_jobs { resend! }

    new_token = gpe.reload.invite_token
    expect(new_token).to be_present
    expect(new_token).not_to eq(old_token)
    expect(ActionMailer::Base.deliveries.last.body.encoded).to include(new_token)

    get guardian_portal_path(token: old_token)
    expect(response).to have_http_status(:not_found)

    get guardian_portal_path(token: new_token)
    expect(response).to have_http_status(:ok)
  end
end
