require "rails_helper"

RSpec.describe SeriesBroadcastJob do
  include ActiveJob::TestHelper

  let(:series) { create(:event_series) }
  let(:owner) { create(:user, email: "kestrel-owner@example.com") }
  let!(:first_event) { create(:event, event_series: series, name: "Kestrel One") }
  let!(:second_event) { create(:event, event_series: series, name: "Kestrel Two") }
  let!(:empty_event) { create(:event, event_series: series, name: "Kestrel Empty") }

  let(:broadcast) do
    SeriesBroadcast.create!(event_series: series, sent_by_user: owner, audience: "confirmed_attendees",
      channels: [ "email" ], subject: "See you at {{event_name}}", body: "<p>Hi {{first_name}}</p>",
      event_scope: "all", status: :sending, sent_at: Time.current)
  end

  before do
    create(:participant_event, event: first_event, status: :complete, participant: create(:participant, legal_first_name: "Tamsin"))
    create(:participant_event, event: second_event, status: :complete, participant: create(:participant, legal_first_name: "Ellis"))
    create(:participant_event, event: second_event, status: :complete, participant: create(:participant, legal_first_name: "Noor"))
  end

  it "creates a copy per event with anyone in the audience and queues each one's send" do
    described_class.perform_now(series_broadcast_id: broadcast.id)

    copies = broadcast.messages.to_a
    expect(copies.map(&:event)).to contain_exactly(first_event, second_event)
    expect(copies).to all(be_draft)
    expect(copies.map(&:screening_cleared?)).to all(be(true))
    expect(broadcast.reload.skipped_event_ids).to eq([ empty_event.id ])
    expect(broadcast.fanned_out_at).to be_present
    copies.each do |copy|
      expect(SeriesBroadcastMessageJob).to have_been_enqueued.with(message_id: copy.id)
    end
  end

  it "doesn't queue a send for a copy that has already gone out" do
    described_class.perform_now(series_broadcast_id: broadcast.id)
    perform_enqueued_jobs(only: SeriesBroadcastMessageJob)
    clear_enqueued_jobs

    broadcast.update_columns(status: "sending")
    described_class.perform_now(series_broadcast_id: broadcast.id)

    expect(SeriesBroadcastMessageJob).not_to have_been_enqueued
    expect(MessageDelivery.count).to eq(3)
  end

  it "does nothing for a broadcast that isn't sending" do
    broadcast.update_columns(status: "draft")

    described_class.perform_now(series_broadcast_id: broadcast.id)

    expect(broadcast.messages).to be_empty
  end

  it "ignores a broadcast that no longer exists" do
    expect { described_class.perform_now(series_broadcast_id: SecureRandom.uuid) }.not_to raise_error
  end

  describe SeriesBroadcastMessageJob do
    it "sends a copy through the event's pipeline without screening it again" do
      allow(BroadcastScreener).to receive(:call)
      SeriesBroadcastJob.perform_now(series_broadcast_id: broadcast.id)
      copy = broadcast.messages.find_by!(event: second_event)

      SeriesBroadcastMessageJob.perform_now(message_id: copy.id)

      expect(copy.reload).to be_sending
      expect(copy.message_deliveries.count).to eq(2)
      expect(BroadcastScreener).not_to have_received(:call)
      expect(MessageDeliveryJob).to have_been_enqueued.with(message_id: copy.id)
    end

    it "screens a copy whose content no longer matches what was cleared, even from a global admin's broadcast" do
      owner.update!(global_role: "global_admin")
      allow(BroadcastScreener).to receive(:call).and_return(
        BroadcastScreener::Result.new(flagged: true, categories: [ "marketing" ], reason: "Sells something.", flagged_by: "model")
      )
      SeriesBroadcastJob.perform_now(series_broadcast_id: broadcast.id)
      copy = broadcast.messages.find_by!(event: second_event)
      copy.update_columns(body: "<p>Buy our merch</p>")

      SeriesBroadcastMessageJob.perform_now(message_id: copy.id)

      expect(BroadcastScreener).to have_received(:call).once
      expect(copy.reload).to be_pending_review
      expect(copy.message_deliveries).to be_empty
    end

    it "won't let a copy's content be edited on its event" do
      SeriesBroadcastJob.perform_now(series_broadcast_id: broadcast.id)
      copy = broadcast.messages.find_by!(event: second_event)

      expect(copy.update(body: "<p>Something else</p>")).to be(false)
      expect(copy.errors.full_messages.join).to include("copy of a series broadcast")
      expect(copy.reload.update(scheduled_at: 1.day.from_now)).to be(true)
    end

    it "leaves an ordinary message alone" do
      message = first_event.messages.create!(audience: "confirmed_attendees", channels: [ "email" ], body: "<p>Hi</p>", sent_by_user: owner)

      SeriesBroadcastMessageJob.perform_now(message_id: message.id)

      expect(message.reload).to be_draft
    end
  end
end
