require "rails_helper"

RSpec.describe "Guardian portal UM confirmation", type: :request do
  let(:event) { create(:event, travel_enabled: true) }
  let(:participant_event) { create(:participant_event, event: event) }
  let(:gpe) { create(:guardian_participant_event, participant_event: participant_event) }
  let(:token) { gpe.generate_invite_token! }

  def participant_info_params(um: false, confirm: nil)
    {
      participant: { legal_first_name: "Kid", legal_last_name: "Tester" },
      medical: { allergies: "" },
      dietary: { diet_type: "" },
      accessibility: { other_needs: "" },
      travel_inbound: {
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
      },
      travel_outbound: { mode: "car", origin_address: "Somewhere" }
    }.merge(confirm.nil? ? {} : { um_guardian_confirmation: confirm })
  end

  it "blocks saving when UM is declared without the adult's confirmation" do
    patch guardian_portal_update_step_path(token: token, step: "participant_info"),
      params: participant_info_params(um: true, confirm: "0")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("unaccompanied minor service")
    expect(participant_event.reload.um_guardian_confirmed_at).to be_nil
  end

  it "stamps the confirmation when the adult confirms" do
    patch guardian_portal_update_step_path(token: token, step: "participant_info"),
      params: participant_info_params(um: true, confirm: "1")

    expect(response).to have_http_status(:redirect)
    expect(participant_event.reload.um_guardian_confirmed_at).to be_present
  end

  context "when the participant has already uploaded UM proof" do
    before do
      participant_event.um_proof.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/evidence.txt")),
        filename: "evidence.txt",
        content_type: "application/pdf"
      )
    end

    it "emails the UM reviewer once the adult double-confirms" do
      expect {
        patch guardian_portal_update_step_path(token: token, step: "participant_info"),
          params: participant_info_params(um: true, confirm: "1")
      }.to have_enqueued_mail(UmReviewMailer, :review_request)

      expect(participant_event.reload.um_review_requested_at).to be_present
    end

    it "does not email again on a repeat save" do
      participant_event.update!(um_review_requested_at: 1.day.ago)

      expect {
        patch guardian_portal_update_step_path(token: token, step: "participant_info"),
          params: participant_info_params(um: true, confirm: "1")
      }.not_to have_enqueued_mail(UmReviewMailer, :review_request)
    end
  end

  it "does not email the reviewer when confirming without uploaded proof" do
    expect {
      patch guardian_portal_update_step_path(token: token, step: "participant_info"),
        params: participant_info_params(um: true, confirm: "1")
    }.not_to have_enqueued_mail(UmReviewMailer, :review_request)
  end

  it "clears the confirmation when UM is no longer declared" do
    participant_event.update!(um_guardian_confirmed_at: 1.day.ago)

    patch guardian_portal_update_step_path(token: token, step: "participant_info"),
      params: participant_info_params(um: false)

    expect(response).to have_http_status(:redirect)
    expect(participant_event.reload.um_guardian_confirmed_at).to be_nil
  end
end
