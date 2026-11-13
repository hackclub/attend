require "rails_helper"

RSpec.describe SeriesBroadcast do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:series) { create(:event_series, name: "Moonbeam") }
  let(:owner) { User.create!(email: "moonbeam-owner@example.com", name: "Ola Owner") }
  let!(:north) { create(:event, event_series: series, name: "Moonbeam North", starts_at: 1.week.from_now, ends_at: 2.weeks.from_now) }
  let!(:south) { create(:event, event_series: series, name: "Moonbeam South", starts_at: 3.weeks.from_now, ends_at: 4.weeks.from_now) }
  let!(:finished) { create(:event, event_series: series, name: "Moonbeam Past", starts_at: 3.weeks.ago, ends_at: 2.weeks.ago) }
  let!(:elsewhere) { create(:event, name: "Unrelated Jam") }

  def register(event, status, email: nil, **participant_attrs)
    participant = create(:participant, **{ email: email }.compact, **participant_attrs)
    create(:participant_event, event: event, participant: participant, status: status)
  end

  def build_broadcast(**attrs)
    described_class.new(event_series: series, sent_by_user: owner, audience: "attendees_incomplete",
      channels: [ "email" ], subject: "Hi from {{event_name}}", body: "<p>Hi {{first_name}}, finish signing up for {{event_name}}.</p>",
      event_scope: "upcoming", **attrs)
  end

  # The fan-out queues each copy's send, so run the two steps in turn.
  def fan_out_and_send
    perform_enqueued_jobs(only: SeriesBroadcastJob)
    perform_enqueued_jobs(only: SeriesBroadcastMessageJob)
  end

  before { allow(BroadcastScreener).to receive(:call).and_return(BroadcastScreener::Result.clear) }

  describe "validations" do
    it "accepts an ordinary broadcast" do
      expect(build_broadcast).to be_valid
    end

    it "refuses audiences that only make sense on one event" do
      expect(build_broadcast(audience: "attendees_in_groups")).not_to be_valid
      expect(build_broadcast(audience: "specific_participants")).not_to be_valid
    end

    it "checks placeholders the way a message does" do
      broadcast = build_broadcast(body: "<p>Hi {{nickname}}</p>")
      expect(broadcast).not_to be_valid
      expect(broadcast.errors.full_messages.to_sentence).to include("Unknown placeholder {{nickname}}")

      guardian_only = build_broadcast(body: "<p>About {{participant_first_name}}</p>")
      expect(guardian_only).not_to be_valid
      expect(build_broadcast(audience: "all_guardians", body: "<p>About {{participant_first_name}}</p>")).to be_valid
    end

    it "refuses a guardian portal link once, not twice" do
      link = "https://attend.example.com/guardian/portal/#{SecureRandom.urlsafe_base64(32)}"
      broadcast = build_broadcast(body: %(<p><a href="#{link}">portal</a></p>))

      expect(broadcast).not_to be_valid
      expect(broadcast.errors.full_messages.grep(/guardian portal link/).size).to eq(1)
    end

    it "refuses images, which each event's copy couldn't show" do
      broadcast = build_broadcast(body: %(<p>Look</p><img src="/rails/active_storage/blobs/redirect/abc/pic.png">))
      expect(broadcast).not_to be_valid
      expect(broadcast.errors[:body].to_sentence).to include("can't include images")
    end

    it "needs picked events to be in the series" do
      expect(build_broadcast(event_scope: "selected", selected_event_ids: [])).not_to be_valid
      expect(build_broadcast(event_scope: "selected", selected_event_ids: [ elsewhere.id ])).not_to be_valid
      expect(build_broadcast(event_scope: "selected", selected_event_ids: [ north.id ])).to be_valid
    end
  end

  describe "#target_events" do
    it "picks upcoming events, every event, or the chosen ones, only in its series" do
      expect(build_broadcast(event_scope: "upcoming").target_events).to contain_exactly(north, south)
      expect(build_broadcast(event_scope: "all").target_events).to contain_exactly(north, south, finished)
      expect(build_broadcast(event_scope: "selected", selected_event_ids: [ south.id ]).target_events).to contain_exactly(south)
    end

    it "counts an event under way as upcoming" do
      running = create(:event, event_series: series, starts_at: 1.day.ago, ends_at: 1.day.from_now)
      expect(build_broadcast.target_events).to include(running)
    end
  end

  describe "#recipient_counts_by_event" do
    it "counts each event's audience in one grouped query" do
      register(north, :in_progress)
      register(north, :invited)
      register(north, :complete)
      register(south, :awaiting_guardian)
      register(finished, :in_progress)
      register(elsewhere, :in_progress)

      broadcast = build_broadcast
      queries = 0
      counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
      counts = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { broadcast.recipient_counts_by_event }

      expect(counts).to eq(north.id => 2, south.id => 1)
      expect(broadcast.recipient_count_estimate).to eq(3)
      expect(queries).to eq(1)
    end

    it "counts a guardian once per event their children are at" do
      guardian = create(:guardian)
      create(:guardian_participant_event, guardian: guardian, participant_event: register(north, :complete))
      create(:guardian_participant_event, guardian: guardian, participant_event: register(north, :complete))
      create(:guardian_participant_event, guardian: guardian, participant_event: register(south, :complete))

      expect(build_broadcast(audience: "all_guardians").recipient_counts_by_event).to eq(north.id => 1, south.id => 1)
    end
  end

  describe "sending" do
    let!(:north_registration) { register(north, :in_progress, legal_first_name: "Pip") }
    let!(:south_registration) { register(south, :invited, legal_first_name: "Juno") }
    let(:broadcast) { build_broadcast.tap(&:save!) }

    before do
      # Nobody at the finished event is still incomplete.
      register(finished, :complete)
    end

    it "screens once, then fans out in the background" do
      expect(broadcast.send!(sender: owner)).to be(true)

      expect(broadcast.reload).to be_sending
      expect(BroadcastScreener).to have_received(:call).once
      expect(SeriesBroadcastJob).to have_been_enqueued.with(series_broadcast_id: broadcast.id)
      expect(broadcast.messages).to be_empty
    end

    it "creates one ordinary message per event and sends each through the event pipeline" do
      broadcast.send!(sender: owner)
      fan_out_and_send

      messages = broadcast.messages.includes(:event).index_by(&:event)
      expect(messages.keys).to contain_exactly(north, south)
      expect(messages.values).to all(be_sending)
      expect(messages.values.map(&:sent_by_user)).to all(eq(owner))
      expect(messages[north].message_deliveries.map(&:participant_event)).to eq([ north_registration ])
      expect(messages[north].subject_for(north_registration.participant)).to eq("Hi from Moonbeam North")
      expect(messages[south].body_as_plain(recipient: south_registration.participant)).to eq("Hi Juno, finish signing up for Moonbeam South.")
      # The copies were screened as part of the broadcast.
      expect(BroadcastScreener).to have_received(:call).once
      expect(MessageDeliveryJob).to have_been_enqueued.twice
    end

    it "is safe to run again: no second copy and no second send" do
      broadcast.send!(sender: owner)
      fan_out_and_send
      deliveries = MessageDelivery.count

      SeriesBroadcastJob.perform_now(series_broadcast_id: broadcast.id)
      broadcast.update_columns(status: "sending")
      broadcast.fan_out!
      perform_enqueued_jobs(only: SeriesBroadcastMessageJob)
      SeriesBroadcastMessageJob.perform_now(message_id: broadcast.messages.first.id)

      expect(broadcast.messages.count).to eq(2)
      expect(MessageDelivery.count).to eq(deliveries)
    end

    it "copes with a copy created by a concurrent fan-out" do
      broadcast.update_columns(status: "sending")
      broadcast.messages.create!(broadcast.send(:copy_attributes, north))

      expect { broadcast.fan_out! }.to change { broadcast.messages.count }.from(1).to(2)
    end

    it "skips events where nobody matches, remembering them" do
      broadcast.update!(event_scope: "all")
      broadcast.send!(sender: owner)
      perform_enqueued_jobs(only: SeriesBroadcastJob)

      expect(broadcast.reload.skipped_event_ids).to eq([ finished.id ])
      expect(broadcast.messages.map(&:event)).to contain_exactly(north, south)
    end

    it "completes once every copy has settled" do
      broadcast.send!(sender: owner)
      fan_out_and_send
      expect(broadcast.reload).to be_sending

      broadcast.messages.each { |message| message.update!(status: :completed) }

      expect(broadcast.reload).to be_completed
    end

    it "completes a copy nobody can be reached by, so it doesn't sit sending forever" do
      north_registration.participant.update_columns(slack_user_id: nil)
      broadcast.update!(channels: [ "slack" ])
      broadcast.send!(sender: owner)
      fan_out_and_send

      expect(broadcast.messages.map(&:status)).to all(eq("completed"))
      expect(broadcast.reload).to be_completed
    end

    it "holds a flagged broadcast for review, filed against the series" do
      allow(BroadcastScreener).to receive(:call).and_return(
        BroadcastScreener::Result.new(flagged: true, categories: [ "marketing" ], reason: "Sells something.", flagged_by: "model")
      )

      expect(broadcast.send!(sender: owner)).to be(false)

      review = broadcast.reload.pending_broadcast_review
      expect(broadcast).to be_pending_review
      expect(review).to have_attributes(event_series: series, event: nil, kind_label: "Series broadcast")
      expect(review.target_name).to eq("Moonbeam (series)")
      expect(SeriesBroadcastJob).not_to have_been_enqueued
    end

    it "screens against the series rather than one event" do
      broadcast.send!(sender: owner)

      expect(BroadcastScreener).to have_received(:call) do |event:, **|
        expect(event.name).to include("Moonbeam", "2 events")
        expect(event.event_series).to eq(series)
        expect(event.starts_at).to be_within(1.second).of(north.starts_at)
      end
    end

    it "goes out when an approved review releases it" do
      allow(BroadcastScreener).to receive(:call).and_return(
        BroadcastScreener::Result.new(flagged: true, categories: [ "spam" ], reason: "Odd.", flagged_by: "heuristics")
      )
      broadcast.send!(sender: owner)
      admin = User.create!(email: "moonbeam-admin@example.com", name: "Ada Admin", global_role: "global_admin")

      broadcast.pending_broadcast_review.approve!(admin)

      expect(broadcast.reload).to be_sending
      expect(SeriesBroadcastJob).to have_been_enqueued
    end

    it "is picked up by the scheduled-messages job when due" do
      broadcast.update!(scheduled_at: 1.hour.from_now)
      broadcast.schedule!(sender: owner)
      expect(broadcast.reload).to be_scheduled

      travel 2.hours do
        ProcessScheduledMessagesJob.perform_now
      end

      expect(broadcast.reload).to be_sending
    end

    it "can be cancelled while scheduled" do
      broadcast.update!(scheduled_at: 1.day.from_now)
      broadcast.schedule!(sender: owner)

      expect(broadcast.cancel!).to be(true)
      expect(broadcast.reload).to be_cancelled
    end
  end

  describe ".totals_for" do
    it "rolls the copies' counts up per broadcast" do
      broadcast = build_broadcast.tap(&:save!)
      broadcast.messages.create!(broadcast.send(:copy_attributes, north)).update_columns(recipient_count: 4, sent_count: 3, failed_count: 1)
      broadcast.messages.create!(broadcast.send(:copy_attributes, south)).update_columns(recipient_count: 2, sent_count: 2, failed_count: 0)

      expect(described_class.totals_for([ broadcast.id ])).to eq(broadcast.id => { events: 2, recipients: 6, delivered: 5, failed: 1 })
    end
  end
end
