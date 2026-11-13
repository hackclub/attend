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

  context "when the event is in a series" do
    let(:series) { create(:event_series) }
    let(:owner) { User.create!(email: "series-owner@example.com", name: "Series Owner", admin_console_beta: false) }
    let(:other_event) { create(:event) }

    before do
      event.update!(event_series: series)
      create(:series_role_assignment, :owner, event_series: series, user: owner)
    end

    [ false, true ].each do |console|
      context(console ? "in the console" : "in the classic admin") do
        before { owner.update!(admin_console_beta: console) }

        it "lets a series owner see and approve held messages for their series only" do
          message.send!(sender: organizer)
          review = message.pending_broadcast_review
          other_message = other_event.messages.create!(audience: "confirmed_attendees", channels: [ "email" ],
            subject: "Elsewhere", body: "<p>Another event's sale</p>", sent_by_user: organizer, status: :draft)
          other_message.send!(sender: organizer)
          other_review = other_message.pending_broadcast_review
          sign_in owner

          get admin_broadcast_reviews_path
          expect(response).to have_http_status(:ok)
          expect(response.body).to include(event.name)
          expect(response.body).not_to include(other_event.name)
          expect(response.body).not_to include("Who gets emailed")

          get admin_broadcast_review_path(other_review)
          expect(response).to redirect_to(root_path)

          post approve_admin_broadcast_review_path(other_review)
          expect(other_message.reload).to be_pending_review

          get admin_broadcast_review_path(review)
          expect(response).to have_http_status(:ok)
          expect(response.body).to include("Approve and send")

          post approve_admin_broadcast_review_path(review)
          expect(response).to redirect_to(admin_broadcast_reviews_path)
          expect(message.reload).to be_sending
          expect(review.reload.decided_by_user).to eq(owner)
        end

        it "doesn't let a series owner approve their own message" do
          own = event.messages.create!(audience: "confirmed_attendees", channels: [ "email" ], subject: "Mine",
            body: "<p>My own sale</p>", sent_by_user: owner, status: :draft)
          own.send!(sender: owner)
          review = own.pending_broadcast_review
          sign_in owner

          get admin_broadcast_review_path(review)
          expect(response).to have_http_status(:ok)
          expect(response.body).to include("You wrote, edited or sent this")
          expect(response.body).not_to include("Approve and send")

          post approve_admin_broadcast_review_path(review)
          expect(own.reload).to be_pending_review
        end
      end
    end

    it "doesn't let a series owner approve a message they edited but someone else sent" do
      PaperTrail.request(whodunnit: owner.id.to_s) { message.update!(subject: "Weekend sale, tweaked") }
      message.send!(sender: organizer)
      review = message.pending_broadcast_review
      sign_in owner

      post approve_admin_broadcast_review_path(review)
      expect(message.reload).to be_pending_review
    end

    it "keeps series organizers out of the queue" do
      series_organizer = User.create!(email: "series-organizer@example.com", name: "Series Organizer")
      create(:series_role_assignment, event_series: series, user: series_organizer)
      message.send!(sender: organizer)
      sign_in series_organizer

      get admin_broadcast_reviews_path
      expect(response).to redirect_to(admin_root_path)

      post approve_admin_broadcast_review_path(message.pending_broadcast_review)
      expect(message.reload).to be_pending_review
    end
  end

  describe "picking who gets emailed" do
    let(:other_admin) { User.create!(email: "other-admin@example.com", name: "Other Admin", global_role: "global_admin") }

    it "saves the picked global admins and ignores anyone else" do
      other_admin
      sign_in admin

      get admin_broadcast_reviews_path
      expect(response.body).to include("Who gets emailed", other_admin.email)

      patch recipients_admin_broadcast_reviews_path, params: { recipient_user_ids: [ "", other_admin.id, organizer.id ] }
      expect(response).to redirect_to(admin_broadcast_reviews_path(anchor: "review-recipients"))
      expect(Setting.broadcast_review_recipient_user_id_list).to eq([ other_admin.id.to_s ])
      expect(AuditLog.where(action: "update_review_recipients")).to exist
    end

    it "is global-admin only" do
      sign_in organizer

      patch recipients_admin_broadcast_reviews_path, params: { recipient_user_ids: [ organizer.id ] }
      expect(Setting.broadcast_review_recipient_user_id_list).to be_empty
    end
  end
end
