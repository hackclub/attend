require "rails_helper"

RSpec.describe "Admin registration change requests", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:participant) { create(:participant) }
  let(:owner) { create(:user) }
  let(:participant_event) { create(:participant_event, event: event, participant: participant) }
  let!(:request_record) do
    participant.update!(user: owner)
    RegistrationChangeRequest.create!(
      participant_event: participant_event,
      requested_by: owner,
      kind: :support,
      staff_audience: :operations,
      requested_changes: {},
      requester_note: "Private operational question"
    )
  end

  it "lets exact-event ops view only their audience and request follow-up" do
    ops = create(:user)
    create(:event_role_assignment, event: event, user: ops, role: :ops)
    sign_in ops

    get admin_event_registration_change_requests_path(event)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Private operational question")

    expect {
      patch request_follow_up_admin_event_registration_change_request_path(event, request_record),
        params: { registration_change_request: { staff_response: "Please add a time we can call." } },
        headers: { "HOST" => "attend.test" }
    }.to have_enqueued_mail(RegistrationCorrectionMailer, :participant_follow_up)

    expect(response).to redirect_to(admin_event_registration_change_request_path(event, request_record))
    expect(request_record.reload).to be_follow_up_needed
    expect(request_record.resolved_by).to eq(ops)
  end

  it "does not expose a consequential request to ops" do
    request_record.update!(kind: :signed_identity, staff_audience: :event_admin,
      requested_changes: { "legal_first_name" => "Corrected" })
    ops = create(:user)
    create(:event_role_assignment, event: event, user: ops, role: :ops)
    sign_in ops

    get admin_event_registration_change_request_path(event, request_record)

    expect(response).to have_http_status(:not_found)
  end

  it "keeps a global admin queue and record lookup inside the selected event" do
    other_event = create(:event)
    other_participant = create(:participant)
    other_owner = create(:user)
    other_participant.update!(user: other_owner)
    other_registration = create(:participant_event, event: other_event, participant: other_participant)
    other_request = RegistrationChangeRequest.create!(
      participant_event: other_registration,
      requested_by: other_owner,
      kind: :support,
      staff_audience: :event_admin,
      requested_changes: {},
      requester_note: "Other event private request"
    )
    global_admin = create(:user, global_role: :global_admin)
    sign_in global_admin

    get admin_event_registration_change_requests_path(event)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Private operational question")
    expect(response.body).not_to include("Other event private request")

    get admin_event_registration_change_request_path(event, other_request)

    expect(response).to have_http_status(:not_found)
  end

  it "shows request lifecycle metadata in participant history without encrypted values" do
    request_record.update!(
      requester_note: "private-health-detail",
      requested_changes: { "legal_first_name" => "SecretName" },
      status: :follow_up_needed,
      staff_response: "private-staff-response"
    )
    global_admin = create(:user, global_role: :global_admin)
    sign_in global_admin

    get history_admin_event_participant_path(event, participant_event)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Registration Change Request")
    expect(response.body).to include("follow_up_needed")
    expect(response.body).not_to include("private-health-detail")
    expect(response.body).not_to include("SecretName")
    expect(response.body).not_to include("private-staff-response")
  end
end
