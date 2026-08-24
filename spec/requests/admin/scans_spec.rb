require "rails_helper"

RSpec.describe "Admin::Scans", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }
  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }
  let(:scan_context) { event.scan_contexts.find_by!(checks_in: true) }

  before { sign_in admin }

  describe "POST /admin/events/:event_slug/scans" do
    {
      "a bare participant ID" => ->(pe) { pe.participant.id },
      "a bare participant event ID" => ->(pe) { pe.id },
      "an Apple Wallet participant deep link" => ->(pe) { "attend://checkin/#{pe.participant.id}" },
      "a participant event deep link" => ->(pe) { "attend://checkin/#{pe.id}" }
    }.each do |description, identifier|
      it "accepts #{description}" do
        expect {
          post admin_event_scans_path(event), params: {
            participant_id: identifier.call(participant_event),
            scan_context_id: scan_context.id
          }, as: :json
        }.to change { participant_event.scans.count }.by(1)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("participant", "participant_event_id")).to eq(participant_event.id)
      end
    end
  end
end
