require "rails_helper"

RSpec.describe SingleDeliveryJob do
  let(:event) { create(:event) }
  let(:message) do
    Message.create!(event: event, audience: "confirmed_attendees", channels: %w[email],
      body: "<p>Hi</p>", sent_by_user: create(:user), status: :sending, sent_at: Time.current)
  end

  def delivery!(status: :pending, channel: "email")
    message.message_deliveries.create!(
      participant_event: create(:participant_event, event: event, status: :complete),
      channel: channel, recipient_email: "someone@example.com", status: status
    )
  end

  def stub_mail(&block)
    mail = instance_double(ActionMailer::MessageDelivery)
    allow(mail).to receive(:deliver_now, &block)
    allow(MessageMailer).to receive(:broadcast).and_return(mail)
  end

  describe "claiming the row" do
    it "sends a pending delivery and marks it delivered" do
      stub_mail { true }
      delivery = delivery!

      described_class.perform_now(delivery_id: delivery.id)

      expect(delivery.reload).to be_delivered
      expect(MessageMailer).to have_received(:broadcast).once
    end

    it "leaves a delivery alone that another job is already sending" do
      stub_mail { true }
      delivery = delivery!(status: :sending)

      described_class.perform_now(delivery_id: delivery.id)

      expect(delivery.reload).to be_sending
      expect(MessageMailer).not_to have_received(:broadcast)
    end

    it "does not resend a delivered row" do
      stub_mail { true }
      delivery = delivery!(status: :delivered)

      described_class.perform_now(delivery_id: delivery.id)

      expect(MessageMailer).not_to have_received(:broadcast)
    end

    it "does not retry a failed row until something resets it to pending" do
      stub_mail { true }
      delivery = delivery!(status: :failed)

      described_class.perform_now(delivery_id: delivery.id)

      expect(delivery.reload).to be_failed
      expect(MessageMailer).not_to have_received(:broadcast)
    end
  end

  describe "settling the message" do
    it "completes the message when every delivery is done, even with some failures" do
      good = delivery!
      bad = delivery!
      calls = 0
      stub_mail do
        calls += 1
        raise "mailbox full" if calls == 2
        true
      end

      described_class.perform_now(delivery_id: good.id)
      expect(message.reload).to be_sending

      described_class.perform_now(delivery_id: bad.id)

      expect(bad.reload).to be_failed
      expect(message.reload).to be_completed
      expect(message.sent_count).to eq(1)
      expect(message.failed_count).to eq(1)
    end

    it "fails the message when nobody was reached" do
      stub_mail { raise "mailbox full" }
      delivery = delivery!

      described_class.perform_now(delivery_id: delivery.id)

      expect(message.reload).to be_failed
    end

    it "waits while other deliveries are still pending" do
      stub_mail { true }
      first = delivery!
      delivery!

      described_class.perform_now(delivery_id: first.id)

      expect(message.reload).to be_sending
    end

    it "re-settles a completed message after a catch-up delivery drains" do
      stub_mail { true }
      message.update!(status: :completed)
      delivery = message.message_deliveries.create!(
        participant_event: create(:participant_event, event: event, status: :complete),
        channel: "email", recipient_email: "later@example.com", catch_up: true
      )

      described_class.perform_now(delivery_id: delivery.id)

      expect(delivery.reload).to be_delivered
      expect(message.reload).to be_completed
      expect(message.sent_count).to eq(1)
    end
  end

  describe "text and WhatsApp deliveries" do
    let(:twilio) { instance_double(TwilioService) }

    before do
      allow(TwilioService).to receive(:new).and_return(twilio)
      allow(twilio).to receive(:send_message).and_return({ sid: "SM1", status: "queued", channel: "whatsapp" })
      event.update!(name: "Example Hackathon")
      message.update!(body: "<p>Doors open at 9am.</p>\n<p>Bring a charger.</p>")
    end

    it "sends the broadcast template with the event, a one-line preview and the delivery" do
      delivery = message.message_deliveries.create!(
        participant_event: create(:participant_event, event: event, status: :complete),
        channel: "sms", recipient_phone: "+447911123456", status: :pending
      )

      described_class.perform_now(delivery_id: delivery.id)

      expect(twilio).to have_received(:send_message).with(
        to: "+447911123456",
        sms_body: a_string_including("View on Attend:"),
        whatsapp_template: WhatsappTemplates::BROADCAST,
        whatsapp_variables: { 1 => "Example Hackathon", 2 => a_string_matching(/\ADoors open at 9am\. ?Bring a charger\.\z/), 3 => delivery.id },
        source: "Broadcast message",
        message_delivery: delivery
      )
      expect(delivery.reload).to have_attributes(status: "delivered", external_id: "SM1")
    end
  end
end
