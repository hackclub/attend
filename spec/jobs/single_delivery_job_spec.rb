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
end
