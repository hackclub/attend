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

  describe "on Postmark::InvalidEmailRequestError for a malformed recipient" do
    def invalid_to_error(address)
      message = "Invalid 'To' address: '#{address}'."
      Postmark::InvalidEmailRequestError.new(300, message, { "ErrorCode" => 300, "Message" => message })
    end

    it "flags the participant and guardian with that address and discards" do
      participant = create(:participant)
      guardian = create(:guardian)
      # rows saved before the address check was tightened can still hold a
      # domain with no top-level part
      participant.update_column(:email, "someone@nowhere")
      guardian.update_column(:email, "someone@nowhere")

      expect { perform_failing_delivery(invalid_to_error("Someone@Nowhere")) }.not_to raise_error

      expect(participant.reload.email_undeliverable_at).to be_present
      expect(guardian.reload.email_undeliverable_at).to be_present
    end

    it "still raises for other malformed-request errors, which are our bug" do
      error = Postmark::InvalidEmailRequestError.new(300, "Provide either email TextBody or HtmlBody or both.", {})

      expect { perform_failing_delivery(error) }.to raise_error(Postmark::InvalidEmailRequestError)
    end
  end

  it "discards a send whose record was deleted before it ran" do
    participant_event = create(:participant_event)
    job = described_class.new("ParticipantMailer", "travel_update_reminder", "deliver_now",
      args: [ participant_event ])
    serialized = job.serialize
    participant_event.destroy!

    expect { ActiveJob::Base.execute(serialized) }.not_to raise_error
  end

  it "re-raises other Postmark errors" do
    expect {
      perform_failing_delivery(Postmark::ApiInputError.new(300, "bad", { "Message" => "bad" }))
    }.to raise_error(Postmark::ApiInputError)
  end
end
