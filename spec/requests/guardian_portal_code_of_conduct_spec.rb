require "rails_helper"

# Guardians can't accept the code of conduct; only the participant can. The
# consents page must never tell a guardian it "needs you" for it.
RSpec.describe "Guardian portal code of conduct row", type: :request do
  let(:event) { create(:event, freedom_waivers_enabled: false) }
  let(:participant) { create(:participant, legal_first_name: "Robin", date_of_birth: 15.years.ago) }
  let(:participant_event) { create(:participant_event, participant: participant, event: event) }
  let(:gpe) { create(:guardian_participant_event, participant_event: participant_event) }
  let(:token) { gpe.generate_invite_token! }

  def code_of_conduct_row
    get guardian_portal_step_path(token: token, step: "consents")
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body).css("li").find { |li| li.text.include?("Code of Conduct & Safeguarding") }.text.squish
  end

  it "says it's waiting on the participant, not on the guardian, before they accept" do
    participant_event.update!(code_of_conduct_accepted_at: nil)

    row = code_of_conduct_row

    expect(row).to include("Waiting on Robin")
    expect(row).not_to include("Needs you")
  end

  it "shows it as agreed once the participant accepts" do
    participant_event.update!(code_of_conduct_accepted_at: Time.current)

    row = code_of_conduct_row

    expect(row).to include("Agreed")
    expect(row).not_to include("Needs you")
  end
end
