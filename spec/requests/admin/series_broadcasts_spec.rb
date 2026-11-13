require "rails_helper"

RSpec.describe "Admin series broadcasts", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:series) { create(:event_series, name: "Starling") }
  let!(:north) { create(:event, event_series: series, name: "Starling North") }
  let!(:south) { create(:event, event_series: series, name: "Starling South") }
  let!(:finished) { create(:event, event_series: series, name: "Starling Past", starts_at: 3.weeks.ago, ends_at: 2.weeks.ago) }

  let(:owner) do
    create(:user, email: "starling-owner@example.com").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
    end
  end

  let!(:north_registration) do
    create(:participant_event, event: north, status: :in_progress,
      participant: create(:participant, legal_first_name: "Wren", email: "wren@example.com"))
  end
  let!(:south_registration) do
    create(:participant_event, event: south, status: :in_progress,
      participant: create(:participant, legal_first_name: "Rook", email: "rook@example.com"))
  end

  let(:params) do
    {
      series_broadcast: {
        subject: "News for {{event_name}}",
        body: "<p>Hi {{first_name}}, finish signing up for {{event_name}}.</p>",
        audience: "attendees_incomplete",
        event_scope: "upcoming",
        channels: [ "", "email" ],
        selected_event_ids: [ "" ]
      }
    }
  end

  before { allow(BroadcastScreener).to receive(:call).and_return(BroadcastScreener::Result.clear) }

  def create_broadcast(**attrs)
    SeriesBroadcast.create!(event_series: series, sent_by_user: owner, subject: "News for {{event_name}}",
      body: "<p>Hi {{first_name}}</p>", audience: "attendees_incomplete", event_scope: "upcoming", channels: [ "email" ], **attrs)
  end

  [ true, false ].each do |console|
    context "with the #{console ? 'console' : 'original'} admin" do
      before do
        owner.update!(admin_console_beta: console)
        sign_in owner
      end

      it "links to broadcasts from the series page" do
        get admin_series_path(series)

        expect(response.body).to include(admin_series_broadcasts_path(series))
      end

      it "lists broadcasts with their totals rolled up from each event's copy" do
        broadcast = create_broadcast(status: :completed, sent_at: 1.hour.ago, subject: "Packing list")
        message = broadcast.messages.create!(broadcast.send(:copy_attributes, north))
        message.update_columns(status: "completed", recipient_count: 7, sent_count: 6, failed_count: 1)

        get admin_series_broadcasts_path(series)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Packing list", "1 event", "6/7 delivered", "1 failed")
      end

      it "renders the compose form" do
        get new_admin_series_broadcast_path(series)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("{{event_name}}", "Starling North", "Upcoming and running events")
      end

      it "saves a draft and goes to the preview, which counts recipients per event" do
        all_events = params.deep_merge(series_broadcast: { event_scope: "all" })
        expect { post admin_series_broadcasts_path(series), params: all_events }.to change(SeriesBroadcast, :count).by(1)

        broadcast = SeriesBroadcast.last
        expect(broadcast).to have_attributes(sent_by_user: owner, channels: [ "email" ], selected_event_ids: [], status: "draft")
        expect(response).to redirect_to(preview_admin_series_broadcast_path(series, broadcast))

        follow_redirect!
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Starling North", "Starling South", "Starling Past")
        expect(response.body).to include("across").and include("2 events")
        expect(response.body).to include("News for Starling") # subject filled in for one real recipient
        expect(response.body).to include("Skipped")
      end

      it "re-renders the form with the reason when it can't be saved" do
        post admin_series_broadcasts_path(series),
          params: params.deep_merge(series_broadcast: { body: "<p>Hi {{nickname}}</p>" })

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Unknown placeholder")
      end

      it "edits a draft" do
        broadcast = create_broadcast

        get edit_admin_series_broadcast_path(series, broadcast)
        expect(response).to have_http_status(:ok)

        patch admin_series_broadcast_path(series, broadcast),
          params: { series_broadcast: { subject: "Updated", event_scope: "selected", selected_event_ids: [ "", south.id ] } }
        expect(response).to redirect_to(preview_admin_series_broadcast_path(series, broadcast))
        expect(broadcast.reload).to have_attributes(subject: "Updated", selected_event_ids: [ south.id ])
      end

      it "sends now, fans out in the background, and shows the per-event breakdown" do
        broadcast = create_broadcast

        post send_now_admin_series_broadcast_path(series, broadcast)
        expect(response).to redirect_to(admin_series_broadcast_path(series, broadcast))
        expect(broadcast.reload).to be_sending

        perform_enqueued_jobs(only: SeriesBroadcastJob)
        perform_enqueued_jobs(only: SeriesBroadcastMessageJob)

        get admin_series_broadcast_path(series, broadcast)
        expect(response).to have_http_status(:ok)
        north_copy = broadcast.messages.find_by!(event: north)
        expect(response.body).to include(admin_event_message_path(north, north_copy))
        expect(response.body).to include("Starling South")
      end

      it "labels the copy on the event's messages pages, linking back" do
        broadcast = create_broadcast(status: :sending, sent_at: Time.current)
        copy = broadcast.messages.create!(broadcast.send(:copy_attributes, north))

        get admin_event_messages_path(north)
        expect(response.body).to include("From a Starling series broadcast", admin_series_broadcast_path(series, broadcast))

        get admin_event_message_path(north, copy)
        expect(response.body).to include("From a Starling series broadcast")
      end

      it "schedules a broadcast with a future send time, and cancels it" do
        broadcast = create_broadcast(scheduled_at: 2.days.from_now)

        post send_now_admin_series_broadcast_path(series, broadcast)
        expect(broadcast.reload).to be_scheduled
        expect(SeriesBroadcastJob).not_to have_been_enqueued

        post cancel_admin_series_broadcast_path(series, broadcast)
        expect(broadcast.reload).to be_cancelled
      end

      it "holds a flagged broadcast and says so" do
        allow(BroadcastScreener).to receive(:call).and_return(
          BroadcastScreener::Result.new(flagged: true, categories: [ "marketing" ], reason: "Sells a thing.", flagged_by: "model")
        )
        broadcast = create_broadcast

        post send_now_admin_series_broadcast_path(series, broadcast)
        follow_redirect!

        expect(broadcast.reload).to be_pending_review
        expect(response.body).to include("Waiting for review")
      end

      it "won't edit or delete a broadcast that has gone out" do
        broadcast = create_broadcast(status: :sending, sent_at: Time.current)

        get edit_admin_series_broadcast_path(series, broadcast)
        expect(response).to redirect_to(admin_series_broadcast_path(series, broadcast))

        expect { delete admin_series_broadcast_path(series, broadcast) }.not_to change(SeriesBroadcast, :count)
      end

      it "deletes a draft" do
        broadcast = create_broadcast

        expect { delete admin_series_broadcast_path(series, broadcast) }.to change(SeriesBroadcast, :count).by(-1)
        expect(response).to redirect_to(admin_series_broadcasts_path(series))
      end
    end
  end

  describe "a held series broadcast in the review queue" do
    let(:admin) { create(:user, email: "starling-admin@example.com", global_role: "global_admin") }

    [ true, false ].each do |console|
      it "shows and approves it (console: #{console})" do
        allow(BroadcastScreener).to receive(:call).and_return(
          BroadcastScreener::Result.new(flagged: true, categories: [ "spam" ], reason: "Odd link.", flagged_by: "heuristics")
        )
        broadcast = create_broadcast
        broadcast.send!(sender: owner)
        review = broadcast.pending_broadcast_review
        admin.update!(admin_console_beta: console)
        sign_in admin

        get admin_broadcast_reviews_path
        expect(response.body).to include("Starling (series)")

        get admin_broadcast_review_path(review)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Held series broadcast", "Incomplete Onboarding")

        post approve_admin_broadcast_review_path(review)
        expect(broadcast.reload).to be_sending
      end
    end

    it "is visible to another owner of the series, who may decide it" do
      other_owner = create(:user, email: "starling-owner-two@example.com")
      SeriesRoleAssignment.create!(user: other_owner, event_series: series, role: "owner")
      allow(BroadcastScreener).to receive(:call).and_return(
        BroadcastScreener::Result.new(flagged: true, categories: [ "spam" ], reason: "Odd link.", flagged_by: "heuristics")
      )
      broadcast = create_broadcast
      broadcast.send!(sender: owner)
      sign_in other_owner

      get admin_broadcast_reviews_path
      expect(response.body).to include("Starling (series)")
      expect(BroadcastReviewPolicy.new(other_owner, broadcast.pending_broadcast_review).decide?).to be(true)
      expect(BroadcastReviewPolicy.new(owner, broadcast.pending_broadcast_review).decide?).to be(false)
    end
  end

  describe "access" do
    it "turns away a series organizer" do
      organizer = create(:user, email: "starling-organizer@example.com")
      SeriesRoleAssignment.create!(user: organizer, event_series: series, role: "organizer")
      sign_in organizer

      get admin_series_broadcasts_path(series)
      expect(response).not_to have_http_status(:ok)

      expect { post admin_series_broadcasts_path(series), params: params }.not_to change(SeriesBroadcast, :count)
    end

    it "turns away an event admin of one of the series' events" do
      event_admin = create(:user, email: "starling-event-admin@example.com")
      create(:event_role_assignment, user: event_admin, event: north, role: "event_admin")
      sign_in event_admin

      get admin_series_broadcasts_path(series)
      expect(response).not_to have_http_status(:ok)

      expect { post admin_series_broadcasts_path(series), params: params }.not_to change(SeriesBroadcast, :count)
    end

    it "doesn't show the series link to an organizer" do
      organizer = create(:user, email: "starling-organizer-two@example.com")
      SeriesRoleAssignment.create!(user: organizer, event_series: series, role: "organizer")
      sign_in organizer

      get admin_series_path(series)
      expect(response.body).not_to include(admin_series_broadcasts_path(series))
    end

    it "lets a global admin in" do
      sign_in create(:user, email: "starling-admin-two@example.com", global_role: "global_admin")

      get admin_series_broadcasts_path(series)
      expect(response).to have_http_status(:ok)
    end
  end
end
