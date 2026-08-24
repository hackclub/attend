require "rails_helper"

RSpec.describe MailDeliveryJob do
  def inactive_recipient_error(*addresses)
    message = "You tried to send to recipient(s) that have been marked as inactive. " \
      "Found inactive addresses: #{addresses.join(', ')}. Inactive recipients are ones " \
      "that have generated a hard bounce, a spam complaint, or a manual suppression."
    Postmark::InactiveRecipientError.new(406, message, { "ErrorCode" => 406, "Message" => message })
  end

  def perform_failing_delivery(error)
    delivery = double("message")
    allow(ParticipantMailer).to receive(:travel_update_reminder).and_return(delivery)
    allow(delivery).to receive(:deliver_now).and_raise(error)

    described_class.perform_now("ParticipantMailer", "travel_update_reminder", "deliver_now", args: [])
  end

  it "is configured as the ActionMailer delivery job" do
    expect(ActionMailer::Base.delivery_job).to eq(described_class)
  end

  describe "on Postmark::InactiveRecipientError" do
    it "discards instead of raising" do
      expect {
        perform_failing_delivery(inactive_recipient_error("dead@example.com"))
      }.not_to raise_error
    end

    it "flags matching participants and guardians as undeliverable" do
      participant = create(:participant, email: "dead@example.com")
      guardian = create(:guardian, email: "dead@example.com")
      bystander = create(:participant, email: "alive@example.com")

      perform_failing_delivery(inactive_recipient_error("dead@example.com"))

      expect(participant.reload.email_undeliverable_at).to be_present
      expect(guardian.reload.email_undeliverable_at).to be_present
      expect(bystander.reload.email_undeliverable_at).to be_nil
    end

    it "still discards when no recipients can be parsed from the error" do
      error = Postmark::InactiveRecipientError.new(406, "unexpected format", { "Message" => "unexpected format" })

      expect { perform_failing_delivery(error) }.not_to raise_error
    end
  end

  it "re-raises other Postmark errors" do
    expect {
      perform_failing_delivery(Postmark::ApiInputError.new(300, "bad", { "Message" => "bad" }))
    }.to raise_error(Postmark::ApiInputError)
  end
end
