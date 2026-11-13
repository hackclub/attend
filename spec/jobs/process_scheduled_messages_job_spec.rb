require "rails_helper"

RSpec.describe ProcessScheduledMessagesJob do
  include ActiveJob::TestHelper

  let(:admin) { create(:user, global_role: "global_admin") }
  let(:event) { create(:event) }
  let(:flagged) do
    BroadcastScreener::Result.new(flagged: true, categories: [ "marketing" ], reason: "Sells something.", flagged_by: "model")
  end

  before do
    create(:participant_event, event: event, status: :complete, participant: create(:participant, legal_first_name: "Wren"))
  end

  def scheduled_message
    message = event.messages.create!(audience: "confirmed_attendees", channels: [ "email" ],
      subject: "Heads up", body: "<p>See you soon</p>", sent_by_user: admin, scheduled_at: 1.minute.from_now)
    message.schedule!(sender: admin)
    message.update_columns(scheduled_at: 1.minute.ago)
    message
  end

  it "sends a global admin's scheduled message untouched since it was scheduled" do
    allow(BroadcastScreener).to receive(:call).and_return(flagged)
    message = scheduled_message

    described_class.perform_now

    expect(BroadcastScreener).not_to have_received(:call)
    expect(message.reload).to be_sending
  end

  it "screens a global admin's scheduled message that was edited afterwards" do
    allow(BroadcastScreener).to receive(:call).and_return(flagged)
    message = scheduled_message
    message.update!(body: "<p>Buy our merch</p>")

    described_class.perform_now

    expect(BroadcastScreener).to have_received(:call).once
    expect(message.reload).to be_pending_review
    expect(message.message_deliveries).to be_empty
  end

  it "screens a global admin's scheduled series broadcast that was edited afterwards" do
    allow(BroadcastScreener).to receive(:call).and_return(flagged)
    broadcast = SeriesBroadcast.create!(event_series: event.event_series || create(:event_series).tap { |s| event.update!(event_series: s) },
      sent_by_user: admin, audience: "confirmed_attendees", channels: [ "email" ], subject: "Heads up",
      body: "<p>See you soon</p>", event_scope: "all", scheduled_at: 1.minute.from_now)
    broadcast.schedule!(sender: admin)
    broadcast.update!(body: "<p>Buy our merch</p>")
    broadcast.update_columns(scheduled_at: 1.minute.ago)

    described_class.perform_now

    expect(BroadcastScreener).to have_received(:call).once
    expect(broadcast.reload).to be_pending_review
    expect(SeriesBroadcastJob).not_to have_been_enqueued
  end
end
