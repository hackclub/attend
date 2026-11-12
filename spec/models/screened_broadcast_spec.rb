require "rails_helper"

RSpec.describe ScreenedBroadcast do
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:organizer) { User.create!(email: "organizer-screen@example.com", name: "Organizer") }
  let(:admin) { User.create!(email: "admin-screen@example.com", name: "Admin", global_role: "global_admin") }
  let(:flagged) do
    BroadcastScreener::Result.new(flagged: true, categories: [ "marketing" ], reason: "Advertises a sponsor's sale.", flagged_by: "model")
  end
  let(:clear) { BroadcastScreener::Result.clear }

  def build_message(**attrs)
    event.messages.create!(audience: "confirmed_attendees", channels: [ "email" ], subject: "Hello",
      body: "<p>Big sale this weekend</p>", sent_by_user: organizer, status: :draft, **attrs)
  end

  describe "Message#send!" do
    it "holds a flagged message for review instead of sending it" do
      allow(BroadcastScreener).to receive(:call).and_return(flagged)
      message = build_message

      expect(message.send!(sender: organizer)).to be(false)

      message.reload
      expect(message).to be_pending_review
      expect(message.message_deliveries).to be_empty
      review = message.pending_broadcast_review
      expect(review).to have_attributes(categories: [ "marketing" ], reason: "Advertises a sponsor's sale.",
        submitted_by_user: organizer, flagged_by: "model", content_digest: message.content_digest)
      expect(enqueued_jobs.map { _1["job_class"] }).not_to include("MessageDeliveryJob")
    end

    it "sends a clear message and remembers it was cleared" do
      allow(BroadcastScreener).to receive(:call).and_return(clear)
      message = build_message

      expect(message.send!(sender: organizer)).to be(true)
      expect(message.reload).to be_sending
      expect(message.screened_digest).to eq(message.content_digest)
    end

    it "doesn't screen what a global admin sends" do
      expect(BroadcastScreener).not_to receive(:call)
      message = build_message

      expect(message.send!(sender: admin)).to be(true)
    end

    it "screens a scheduled message as its author when the job sends it" do
      allow(BroadcastScreener).to receive(:call).and_return(flagged)
      message = build_message(status: :scheduled, scheduled_at: 1.minute.ago)

      ProcessScheduledMessagesJob.perform_now

      expect(message.reload).to be_pending_review
      expect(message.pending_broadcast_review.submitted_by_user).to eq(organizer)
    end

    it "doesn't screen again content that was already cleared" do
      allow(BroadcastScreener).to receive(:call).and_return(clear)
      message = build_message(scheduled_at: 1.day.from_now)
      message.schedule!(sender: organizer)

      message.update!(scheduled_at: 1.minute.ago)
      message.send!

      expect(BroadcastScreener).to have_received(:call).once
    end

    it "screens again after the content is edited" do
      allow(BroadcastScreener).to receive(:call).and_return(clear)
      message = build_message(scheduled_at: 1.day.from_now)
      message.schedule!(sender: organizer)

      message.update!(body: "<p>Now with a different body</p>", scheduled_at: 1.minute.ago)
      message.send!

      expect(BroadcastScreener).to have_received(:call).twice
    end
  end

  describe "Message#schedule!" do
    it "holds a flagged message before its send time" do
      allow(BroadcastScreener).to receive(:call).and_return(flagged)
      message = build_message(scheduled_at: 1.day.from_now)

      expect(message.schedule!(sender: organizer)).to be(false)
      expect(message.reload).to be_pending_review
    end
  end

  describe "reviewing a held message" do
    let(:message) do
      allow(BroadcastScreener).to receive(:call).and_return(flagged)
      build_message.tap { _1.send!(sender: organizer) }.reload
    end
    let(:review) { message.pending_broadcast_review }

    it "emails the reviewers when it's held" do
      expect { review }.to have_enqueued_mail(BroadcastReviewMailer, :flagged)
    end

    it "sends it when approved" do
      review.approve!(admin)

      expect(review.reload).to have_attributes(status: "approved", decided_by_user: admin)
      expect(message.reload).to be_sending
      expect(message.screened_digest).to eq(message.content_digest)
      expect(BroadcastScreener).to have_received(:call).once
    end

    it "puts an approved message with a future time back on its schedule" do
      message.update_columns(scheduled_at: 1.day.from_now)

      review.approve!(admin)

      expect(message.reload).to be_scheduled
    end

    it "returns it to draft with the note when rejected" do
      review.reject!(admin, note: "Please drop the sponsor discount.")

      expect(review.reload).to have_attributes(status: "rejected", decision_note: "Please drop the sponsor discount.")
      expect(message.reload).to be_draft
      expect(message.message_deliveries).to be_empty
    end

    it "can't be decided twice" do
      review.reject!(admin)

      expect { review.approve!(admin) }.to raise_error(BroadcastReview::DecisionError)
      expect(message.reload).to be_draft
    end

    it "is withdrawn when the author cancels the message" do
      held = review
      expect(message.cancel!).to be(true)

      expect(message.reload).to be_cancelled
      expect(held.reload).to be_withdrawn
      expect { held.approve!(admin) }.to raise_error(BroadcastReview::DecisionError)
    end
  end

  describe "SlackBlast#dispatch!" do
    let(:blast) do
      SlackBlast.create!(event: event, sent_by_user: organizer, status: :pending, recipient_count: 1,
        message: %(<p>Grab the deal <a href="https://bit.ly/x">here</a></p>))
    end

    it "screens the link targets as well as the text" do
      expect(blast.screening_text).to include("Grab the deal here", "https://bit.ly/x")
    end

    it "holds a flagged blast and doesn't start the job" do
      allow(BroadcastScreener).to receive(:call).and_return(flagged)

      expect { expect(blast.dispatch!(sender: organizer)).to be(false) }.not_to have_enqueued_job(SlackBlastJob)
      expect(blast.reload).to be_pending_review
    end

    it "starts the job once approved, and retires the blast if rejected" do
      allow(BroadcastScreener).to receive(:call).and_return(flagged)
      blast.dispatch!(sender: organizer)

      expect { blast.pending_broadcast_review.approve!(admin) }.to have_enqueued_job(SlackBlastJob)
      expect(blast.reload).to be_pending

      other = SlackBlast.create!(event: event, sent_by_user: organizer, status: :pending, recipient_count: 1, message: "<p>Sale</p>")
      other.dispatch!(sender: organizer)
      other.pending_broadcast_review.reject!(admin)
      expect(other.reload).to be_rejected
    end

    it "sends a clear blast straight away" do
      allow(BroadcastScreener).to receive(:call).and_return(clear)

      expect { expect(blast.dispatch!(sender: organizer)).to be(true) }.to have_enqueued_job(SlackBlastJob)
    end
  end
end
