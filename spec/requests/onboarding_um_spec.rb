require "rails_helper"

RSpec.describe "Onboarding unaccompanied minor verification", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, accommodation_enabled: false) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 1)
  end

  before { sign_in user }

  def plane_travel_params(um: false)
    {
      mode: "plane",
      is_unaccompanied_minor: um ? "1" : "0",
      travel_legs_attributes: {
        "0" => {
          position: "0",
          flight_code: "LH1234",
          departure_airport: "LHR",
          arrival_airport: "VIE",
          departure_time: "2026-08-01T10:00",
          arrival_time: "2026-08-01T13:00"
        }
      }
    }
  end

  describe "PATCH /onboarding/travel" do
    it "blocks the step when UM is declared without proof" do
      patch onboarding_step_path(step: "travel", event_id: event.id), params: {
        travel_inbound: plane_travel_params(um: true),
        travel_outbound: plane_travel_params
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("upload proof of your UM booking")
      expect(participant_event.reload.um_proof).not_to be_attached
    end

    it "attaches the proof and marks the UM status pending" do
      patch onboarding_step_path(step: "travel", event_id: event.id), params: {
        travel_inbound: plane_travel_params(um: true),
        travel_outbound: plane_travel_params,
        um_proof: fixture_file_upload("evidence.txt", "application/pdf")
      }

      expect(response).to have_http_status(:redirect)
      participant_event.reload
      expect(participant_event.um_proof).to be_attached
      expect(participant_event).to be_um_pending
    end

    it "does not require proof when UM is not declared" do
      patch onboarding_step_path(step: "travel", event_id: event.id), params: {
        travel_inbound: plane_travel_params,
        travel_outbound: plane_travel_params
      }

      expect(response).to have_http_status(:redirect)
      expect(participant_event.reload).to be_um_none
    end

    it "resets an approved status back to pending when new proof is uploaded" do
      participant_event.update!(um_status: :approved, um_verified_at: Time.current)

      patch onboarding_step_path(step: "travel", event_id: event.id), params: {
        travel_inbound: plane_travel_params(um: true),
        travel_outbound: plane_travel_params,
        um_proof: fixture_file_upload("evidence.txt", "application/pdf")
      }

      participant_event.reload
      expect(participant_event).to be_um_pending
      expect(participant_event.um_verified_at).to be_nil
    end
  end

  describe "POST /onboarding/complete" do
    before do
      participant_event.travels.create!(direction: "inbound", mode: "plane", is_unaccompanied_minor: true)
      participant_event.travels.create!(direction: "outbound", mode: "plane")
      participant_event.update!(um_status: :pending, onboarding_step: 10)
      participant_event.um_proof.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/evidence.txt")),
        filename: "evidence.txt",
        content_type: "application/pdf"
      )
      create(:guardian_participant_event, participant_event: participant_event)
    end

    it "shows the pickup/dropoff notice but does not email before the guardian double-confirms" do
      expect {
        post complete_onboarding_path(event_id: event.id), params: {
          code_of_conduct_accepted: "1",
          code_of_conduct_signature: "John Doe"
        }
      }.not_to have_enqueued_mail(UmReviewMailer, :review_request)

      expect(flash[:notice]).to include("pickup/dropoff information within 2 weeks of the event")
      expect(participant_event.reload.um_review_requested_at).to be_nil
    end

    it "emails the UM reviewer when the guardian has already double-confirmed" do
      participant_event.update!(um_guardian_confirmed_at: 1.hour.ago)

      expect {
        post complete_onboarding_path(event_id: event.id), params: {
          code_of_conduct_accepted: "1",
          code_of_conduct_signature: "John Doe"
        }
      }.to have_enqueued_mail(UmReviewMailer, :review_request)

      expect(participant_event.reload.um_review_requested_at).to be_present
    end

    it "does not email twice on resubmission" do
      participant_event.update!(um_guardian_confirmed_at: 1.day.ago, um_review_requested_at: 1.day.ago)

      expect {
        post complete_onboarding_path(event_id: event.id), params: {
          code_of_conduct_accepted: "1",
          code_of_conduct_signature: "John Doe"
        }
      }.not_to have_enqueued_mail(UmReviewMailer, :review_request)
    end
  end
end
