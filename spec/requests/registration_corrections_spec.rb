require "rails_helper"

RSpec.describe "Registration corrections", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:participant) { create(:participant, preferred_name: "Before") }
  let(:owner) { create(:user) }
  let(:participant_event) { create(:participant_event, event: event, participant: participant, status: :complete) }

  before do
    participant.update!(user: owner)
    sign_in owner
  end

  it "updates routine contact details without reopening registration" do
    staff = create(:user)
    create(:event_role_assignment, event: event, user: staff, role: :event_admin)

    expect {
    patch dashboard_event_correction_path(participant_event, section: "contact"), params: {
      participant: { preferred_name: "After", pronouns: "they/them", email: participant.email,
                     phone: "+12025550123", tshirt_size: "M", address_line_1: "1 Main St",
                     city: "London", state: "London", postal_code: "E1 1AA", country_of_residence: "GB" }
    }
    }.to have_enqueued_mail(RegistrationCorrectionMailer, :staff_notification)

    expect(response).to redirect_to(dashboard_event_path(participant_event))
    expect(participant.reload.preferred_name).to eq("After")
    expect(participant_event.reload).to be_complete
    expect(participant.versions.last.whodunnit).to eq(owner.id.to_s)
  end

  it "creates an identity request without changing signed identity" do
    staff = create(:user)
    create(:event_role_assignment, event: event, user: staff, role: :event_admin)

    expect {
      post dashboard_event_registration_change_requests_path(participant_event), params: {
        registration_change_request: {
          kind: "signed_identity",
          requested_changes: { legal_first_name: "Corrected", date_of_birth: "2008-01-02" },
          requester_note: "The spelling is wrong"
        }
      }
    }.to change(RegistrationChangeRequest, :count).by(1)
      .and have_enqueued_mail(RegistrationCorrectionMailer, :staff_notification)

    request_record = RegistrationChangeRequest.last
    expect(request_record).to be_pending
    expect(request_record.requested_changes["legal_first_name"]).to eq("Corrected")
    expect(participant.reload.legal_first_name).not_to eq("Corrected")
  end

  it "does not let another attendee open the correction form" do
    other = create(:user)
    other_participant = create(:participant, user: other)
    create(:participant_event, event: event, participant: other_participant)
    sign_in other

    get edit_dashboard_event_correction_path(participant_event, section: "contact")

    expect(response).to have_http_status(:not_found)
  end

  it "renders and updates the complete accessibility field set" do
    participant_event.create_medical!
    participant_event.create_dietary!(diet_type: :omnivore)
    participant_event.create_accessibility!

    get edit_dashboard_event_correction_path(participant_event, section: "health")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="accessibility[has_adhd]"')
    expect(response.body).to include('name="accessibility[uses_wheelchair]"')
    expect(response.body).to include('name="accessibility[needs_captioning]"')

    patch dashboard_event_correction_path(participant_event, section: "health"), params: {
      accessibility: {
        has_adhd: "1",
        uses_wheelchair: "1",
        needs_captioning: "1",
        light_sensitivity: "1",
        religious_practices: "Daily prayer",
        unavailable_times: "Friday afternoon"
      },
      medical: {
        allergy_severity: "severe",
        emergency_action_plan: "Call emergency services",
        additional_notes: "Carry spare medication"
      }
    }

    expect(response).to redirect_to(dashboard_event_path(participant_event))
    accessibility = participant_event.accessibility.reload
    expect(accessibility).to be_has_adhd
    expect(accessibility).to be_uses_wheelchair
    expect(accessibility).to be_needs_captioning
    expect(accessibility).to be_light_sensitivity
    expect(accessibility.religious_practices).to eq("Daily prayer")
    expect(accessibility.unavailable_times).to eq("Friday afternoon")
    expect(participant_event.medical.reload).to have_attributes(
      allergy_severity: "severe", emergency_action_plan: "Call emergency services",
      additional_notes: "Carry spare medication"
    )
  end

  it "rejects guardian replacement requests for an adult registration" do
    participant_event
    participant.update!(date_of_birth: 25.years.ago)

    expect {
      post dashboard_event_registration_change_requests_path(participant_event), params: {
        registration_change_request: {
          kind: "guardian",
          requested_changes: {
            legal_first_name: "New",
            legal_last_name: "Guardian",
            email: "new-guardian@example.com",
            phone: "+12025550995",
            relationship: "Parent"
          }
        }
      }
    }.not_to change(RegistrationChangeRequest, :count)

    expect(response).to redirect_to(dashboard_event_path(participant_event))
  end

  it "does not show an ineligible guardian replacement action on the dashboard" do
    participant_event
    participant.update!(date_of_birth: 25.years.ago)

    get dashboard_event_path(participant_event)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Parent or guardian")
    expect(response.body).not_to include(edit_dashboard_event_correction_path(participant_event, section: :guardian))
  end
end
