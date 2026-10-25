require "rails_helper"

RSpec.describe MessageDeliveryJob do
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:message) do
    Message.create!(event: event, audience: "confirmed_attendees", channels: %w[email],
      body: "<p>Hi</p>", sent_by_user: create(:user), status: :sending, sent_at: Time.current)
  end

  def delivery!(status: :pending)
    message.message_deliveries.create!(
      participant_event: create(:participant_event, event: event, status: :complete),
      channel: "email", recipient_email: "someone@example.com", status: status
    )
  end

  it "fans out every pending delivery when given no ids" do
    pending = delivery!
    delivery!(status: :delivered)
    delivery!(status: :failed)

    expect { described_class.perform_now(message_id: message.id) }
      .to have_enqueued_job(SingleDeliveryJob).with(delivery_id: pending.id).exactly(:once)
  end

  it "fans out only the given ids, still skipping any that are no longer pending" do
    original = delivery!
    catch_up = delivery!
    already_sent = delivery!(status: :delivered)

    expect { described_class.perform_now(message_id: message.id, delivery_ids: [ catch_up.id, already_sent.id ]) }
      .to have_enqueued_job(SingleDeliveryJob).with(delivery_id: catch_up.id).exactly(:once)
    expect(enqueued_jobs.map { |job| job["arguments"].first["delivery_id"] }).not_to include(original.id)
  end
end
