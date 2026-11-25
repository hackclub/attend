require "rails_helper"

# The message form tells staff when some of the event's people can't be
# texted, and greys out SMS for an event in a country we can't text unless
# WhatsApp can reach people there instead.
RSpec.describe "Admin message form SMS coverage", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-sms@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event, location_country: "United States") }
  let(:whatsapp) { false }

  before do
    allow(Setting).to receive(:twilio_enabled?).and_return(true)
    allow(Setting).to receive(:whatsapp_enabled?).and_return(whatsapp)
    sign_in admin
  end

  def sms_checkbox
    Nokogiri::HTML(response.body).at_css("input#channel_sms")
  end

  [ true ].each do |console|
    context "(console: #{console})" do
      it "lists the countries where people can't be texted" do
        create(:participant_event, event:, participant: create(:participant, phone: "+998901234567"))
        create(:participant_event, event:, participant: create(:participant, phone: "+998901234568"))
        create(:participant_event, event:, participant: create(:participant, phone: "+639171234567"))

        get new_admin_event_message_path(event_slug: event.slug)

        expect(response.body).to include("SMS isn&#39;t available in some countries")
          .and include("Uzbekistan (2)").and include("the Philippines (1)")
        expect(sms_checkbox["disabled"]).to be_nil
      end

      it "says nothing when everyone can be texted" do
        create(:participant_event, event:, participant: create(:participant, phone: "+14155551234"))

        get new_admin_event_message_path(event_slug: event.slug)

        expect(response.body).not_to include("sms-coverage-notice")
      end

      context "for an event in a country we can't text" do
        let(:event) { create(:event, location_country: "Uzbekistan") }

        it "greys out SMS" do
          get new_admin_event_message_path(event_slug: event.slug)

          expect(sms_checkbox["disabled"]).to be_present
          expect(response.body).to include("SMS isn&#39;t available in Uzbekistan.")
        end

        context "with WhatsApp on" do
          let(:whatsapp) { true }

          it "keeps the channel for WhatsApp" do
            get new_admin_event_message_path(event_slug: event.slug)

            expect(sms_checkbox["disabled"]).to be_nil
            expect(response.body).to include("SMS / WhatsApp").and include("get WhatsApp only")
          end
        end
      end
    end
  end
end
