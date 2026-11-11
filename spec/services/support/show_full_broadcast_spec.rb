require "rails_helper"

RSpec.describe "Tapping Show it here on a WhatsApp broadcast" do
  let(:twilio) { instance_double(TwilioService) }
  let(:event) { create(:event, name: "Example Hackathon") }
  let(:message) do
    Message.create!(event: event, audience: "confirmed_attendees", channels: %w[sms], subject: "Update",
                    body: "<p>Doors open at 9am.</p><p>Bring a charger.</p>", sent_by_user: create(:user))
  end
  let(:delivery) do
    message.message_deliveries.create!(participant_event: create(:participant_event, event: event), channel: "sms", recipient_phone: "+447911123456", status: "delivered", external_id: "SMwa1")
  end

  before do
    AutomatedSmsLog.create!(phone_number: "+447911123456", body: "preview", channel: "whatsapp", twilio_sid: "SMwa1",
                            message_delivery: delivery, sent_at: Time.current)
    allow(TwilioService).to receive(:new).and_return(twilio)
    allow(twilio).to receive(:send_whatsapp_text)
    allow(twilio).to receive(:send_message)
  end

  def tap_button(original_sid: "SMwa1", from: "whatsapp:+447911123456")
    Support::ProcessIncomingTwilioMessage.call(
      "From" => from, "To" => "whatsapp:+15075550100", "Body" => "Show it here", "MessageSid" => "SMin1",
      "ButtonText" => "Show it here", "ButtonPayload" => "show_it_here", "OriginalRepliedMessageSid" => original_sid
    )
  end

  it "replies with the whole broadcast and opens no ticket" do
    expect { tap_button }.not_to change(Ticket, :count)

    expect(twilio).to have_received(:send_whatsapp_text).with(
      to: "+447911123456",
      body: a_string_including("*Example Hackathon*", "Doors open at 9am.", "Bring a charger.", "View on Attend: https://"),
      source: "Broadcast message"
    )
  end

  it "treats a tap on something that isn't one of our broadcasts as a normal message" do
    expect { tap_button(original_sid: "SMunknown") }.to change(Ticket, :count).by(1)

    expect(twilio).not_to have_received(:send_whatsapp_text)
  end

  it "won't send someone else's broadcast" do
    expect { tap_button(from: "whatsapp:+447911123999") }.to change(Ticket, :count).by(1)

    expect(twilio).not_to have_received(:send_whatsapp_text)
  end
end
