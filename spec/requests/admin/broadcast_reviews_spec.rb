require "rails_helper"

RSpec.describe "Admin::BroadcastReviews", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:admin) { User.create!(email: "reviewer@example.com", name: "Reviewer", global_role: "global_admin", admin_console_beta: false) }
  let(:organizer) { User.create!(email: "organizer@example.com", name: "Organizer", admin_console_beta: false) }
  let(:flagged) do
    BroadcastScreener::Result.new(flagged: true, categories: [ "marketing" ], reason: "Advertises a sponsor's sale.", flagged_by: "model")
  end
  let(:message) do
    event.messages.create!(audience: "confirmed_attendees", channels: [ "email" ], subject: "Weekend sale",
      body: "<p>Half price at our sponsor's shop</p>", sent_by_user: organizer, status: :draft)
  end

  before do
    create(:event_role_assignment, event: event, user: organizer, role: "event_admin")
    allow(BroadcastScreener).to receive(:call).and_return(flagged)
  end

  [ false, true ].each do |console|
    context(console ? "in the console" : "in the classic admin") do
      before do
        admin.update!(admin_console_beta: console)
        organizer.update!(admin_console_beta: console)
      end

      it "holds an organizer's Send now and tells them why" do
        sign_in organizer
        post send_now_admin_event_message_path(event_slug: event.slug, id: message)

        expect(message.reload).to be_pending_review
        expect(flash[:alert]).to include("waiting for a Hack Club admin")

        get admin_event_message_path(event_slug: event.slug, id: message)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Waiting for review", "Advertises a sponsor&#39;s sale.")
      end

      it "lists held messages and lets a global admin approve one" do
        message.send!(sender: organizer)
        review = message.pending_broadcast_review
        sign_in admin

        get admin_broadcast_reviews_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(event.name, "Advertises a sponsor&#39;s sale.")

        get admin_broadcast_review_path(review)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Half price at our sponsor")

        post approve_admin_broadcast_review_path(review)
        expect(response).to redirect_to(admin_broadcast_reviews_path)
        expect(message.reload).to be_sending
        expect(AuditLog.where(action: "approve_broadcast", record_type: "BroadcastReview", record_id: review.id)).to exist
      end

      it "rejects with a note the organizer sees on the draft" do
        message.send!(sender: organizer)
        review = message.pending_broadcast_review
        sign_in admin

        post reject_admin_broadcast_review_path(review), params: { decision_note: "Drop the sale link, please." }
        expect(message.reload).to be_draft
        expect(AuditLog.where(action: "reject_broadcast", record_id: review.id)).to exist

        sign_in organizer
        get admin_event_message_path(event_slug: event.slug, id: message)
        expect(response.body).to include("Not approved", "Drop the sale link, please.")
      end
    end
  end

  it "keeps the queue to global admins" do
    message.send!(sender: organizer)
    sign_in organizer

    get admin_broadcast_reviews_path
    expect(response).to redirect_to(admin_root_path)

    post approve_admin_broadcast_review_path(message.pending_broadcast_review)
    expect(message.reload).to be_pending_review
  end

  it "holds a flagged Slack blast instead of queueing it" do
    create(:participant_event, event: event, status: :complete, participant: create(:participant, slack_user_id: "U0TEST"))
    sign_in organizer

    expect {
      post admin_event_slack_blasts_path(event_slug: event.slug), params: { message: "<p>Sale!</p>" }
    }.not_to have_enqueued_job(SlackBlastJob)

    blast = SlackBlast.last
    expect(blast).to be_pending_review
    expect(flash[:alert]).to include("waiting for a Hack Club admin")
  end
end
