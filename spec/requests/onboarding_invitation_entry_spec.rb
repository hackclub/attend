require "rails_helper"

RSpec.describe "onboarding invitation entry", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) do
    create(:event,
      name: "Trailblazer",
      starts_at: Time.zone.local(2026, 10, 2, 9),
      ends_at: Time.zone.local(2026, 10, 4, 17),
      venue_name: "Summit Hall",
      location_city: "Oakland",
      support_email: "trailblazer@hackclub.com")
  end
  let(:invitation) { create(:invitation, event: event, email: "invited@example.com") }

  it "shows the invited event before authentication" do
    get onboarding_path(invite: invitation.token)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Register for Trailblazer")
    expect(response.body).to include("October 2 - 4, 2026")
    expect(response.body).to include("Summit Hall")
    expect(response.body).to include("clear photo of your face")
    expect(response.body).to include("guardian contact details if you will be under 18")
    expect(response.body).to include(user_hack_club_omniauth_authorize_path)
    expect(response.body).to include("trailblazer@hackclub.com")
  end

  it "returns a matching account to the invited event after authentication" do
    get onboarding_path(invite: invitation.token)
    user = create(:user, email: invitation.email)

    sign_in user

    expect {
      get onboarding_path
    }.to change(ParticipantEvent, :count).by(1)

    participant_event = ParticipantEvent.last
    expect(participant_event.event).to eq(event)
    expect(participant_event.participant.user).to eq(user)
    expect(invitation.reload).to be_accepted
    expect(response).to redirect_to(onboarding_step_path(step: "profile", event_id: event.id))

    delete destroy_user_session_path
    expect(response).to redirect_to(root_path)
  end

  it "explains an account mismatch before linking or creating records" do
    user = create(:user, email: "wrong@example.com")
    sign_in user

    expect {
      get onboarding_path(invite: invitation.token)
    }.to not_change(Participant, :count).and not_change(ParticipantEvent, :count)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("This invitation was sent to invited@example.com")
    expect(response.body).to include("You're signed in as wrong@example.com")
    expect(response.body).to include("Switch Hack Club Account")
    expect(response.body).to include(destroy_user_session_path)
    expect(response.body).to include("trailblazer@hackclub.com")
    expect(invitation.reload).not_to be_accepted
  end

  it "keeps the invited event while switching accounts" do
    sign_in create(:user, email: "wrong@example.com")
    get onboarding_path(invite: invitation.token)

    delete destroy_user_session_path

    expect(response).to redirect_to(onboarding_path(invite: invitation.token))
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Register for Trailblazer")
    expect(response.body).to include("Continue with Hack Club")

    sign_in create(:user, email: invitation.email)

    expect {
      get onboarding_path
    }.to change(ParticipantEvent, :count).by(1)

    expect(ParticipantEvent.last.event).to eq(event)
    expect(invitation.reload).to be_accepted
    expect(response).to redirect_to(onboarding_step_path(step: "profile", event_id: event.id))
  end

  it "does not use an already accepted invitation to create another registration" do
    invitation.update!(accepted_at: 1.day.ago)
    sign_in create(:user, email: invitation.email)

    expect {
      get onboarding_path(invite: invitation.token)
    }.to not_change(Participant, :count).and not_change(ParticipantEvent, :count)

    expect(response).to have_http_status(:gone)
    expect(response.body).to include("This invitation has already been used")
    expect(response.body).to include("trailblazer@hackclub.com")
  end

  it "lets the matching account resume an existing registration from an accepted invitation" do
    user = create(:user, email: invitation.email)
    participant = create(:participant, email: invitation.email, user: user)
    participant_event = create(:participant_event, participant: participant, event: event, onboarding_step: 0)
    invitation.update!(accepted_at: 1.day.ago)
    sign_in user

    expect {
      get onboarding_path(invite: invitation.token)
    }.to not_change(ParticipantEvent, :count)

    expect(response).to redirect_to(onboarding_step_path(step: "profile", event_id: event.id))
    expect(participant_event.reload.event).to eq(event)

    delete destroy_user_session_path
    expect(response).to redirect_to(root_path)
  end

  it "gives an expired invitation an event-specific support route without granting access" do
    invitation.update_column(:expires_at, 1.day.ago)

    expect {
      get onboarding_path(invite: invitation.token)
    }.to not_change(Participant, :count).and not_change(ParticipantEvent, :count)

    expect(response).to have_http_status(:gone)
    expect(response.body).to include("This invitation has expired")
    expect(response.body).to include("Trailblazer")
    expect(response.body).to include("trailblazer@hackclub.com")
    expect(response.body).to include("Sign in to resume")
    expect(invitation.reload).not_to be_accepted
  end

  it "lets the matching account resume an existing registration from an expired link" do
    user = create(:user, email: invitation.email)
    participant = create(:participant, email: invitation.email, user: user)
    create(:participant_event, participant: participant, event: event, onboarding_step: 0)
    invitation.update_column(:expires_at, 1.day.ago)
    sign_in user

    get onboarding_path(invite: invitation.token)

    expect(response).to redirect_to(onboarding_step_path(step: "profile", event_id: event.id))
    expect(invitation.reload).not_to be_accepted
  end

  it "does not use an expired invitation to create a registration" do
    invitation.update_column(:expires_at, 1.day.ago)
    sign_in create(:user, email: invitation.email)

    expect {
      get onboarding_path(invite: invitation.token)
    }.to not_change(Participant, :count).and not_change(ParticipantEvent, :count)

    expect(response).to have_http_status(:gone)
    expect(response.body).to include("request a new invitation")
  end

  it "shows a generic recovery route for an invalid invitation" do
    get onboarding_path(invite: "not-a-real-token")

    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("This invitation link is invalid")
    expect(response.body).to include("team@hackclub.com")
    expect(response.body).not_to include("Trailblazer")
  end

  it "keeps an explicit event continuation ahead of stale invitation context" do
    other_event = create(:event)
    user = create(:user, email: "wrong@example.com")
    participant = create(:participant, email: user.email, user: user)
    create(:participant_event, participant: participant, event: other_event, onboarding_step: 0)
    sign_in user
    get onboarding_path(invite: invitation.token)

    get onboarding_path(event_id: other_event.id)

    expect(response).to redirect_to(onboarding_step_path(step: "profile", event_id: other_event.id))
  end

  it "stores a signed-out explicit event continuation ahead of stale invitation context" do
    other_event = create(:event)
    user = create(:user, email: "returning@example.com")
    participant = create(:participant, email: user.email, user: user)
    create(:participant_event, participant: participant, event: other_event, onboarding_step: 0)

    get onboarding_path(invite: invitation.token)
    get onboarding_path(event_id: other_event.id)

    stored_continuation = request.session["user_return_to"]
    expect(stored_continuation).to eq(onboarding_path(event_id: other_event.id))
    expect(request.session[:invitation_token]).to be_nil

    sign_in user
    get stored_continuation
    expect(response).to redirect_to(onboarding_step_path(step: "profile", event_id: other_event.id))
    expect(invitation.reload).not_to be_accepted
  end
end
