require "rails_helper"

RSpec.describe Message, type: :model do
  let(:event) { create(:event) }
  let(:sender) { create(:user) }

  def message_for(audience)
    Message.new(event: event, audience: audience, channels: [ "email" ], sent_by_user: sender)
  end

  # Registers someone the way the invite API does: an invitation plus a
  # roster entry sitting at `invited` until they open the wizard.
  def invite!(email, sent: true)
    participant = create(:participant, email: email)
    invitation = Invitation.create!(event: event, email: email)
    invitation.mark_sent! if sent
    create(:participant_event, participant: participant, event: event, status: :invited)
  end

  describe "#recipients for all_attendees" do
    it "includes an invitee whose invitation has been sent" do
      pe = invite!("notified@example.com")

      expect(message_for("all_attendees").recipients).to include(pe)
    end

    it "excludes an invitee whose invitation is still held" do
      pe = invite!("held@example.com", sent: false)

      # The hold exists to keep the event from them until it is released;
      # a broadcast would be exactly the leak it prevents.
      expect(message_for("all_attendees").recipients).not_to include(pe)
    end

    it "matches the invitation to the participant across email casing" do
      participant = create(:participant, email: "Mixed@Example.com")
      Invitation.create!(event: event, email: "mixed@example.com").mark_sent!
      pe = create(:participant_event, participant: participant, event: event, status: :invited)

      expect(message_for("all_attendees").recipients).to include(pe)
    end

    it "ignores an invitation sent for a different event" do
      participant = create(:participant, email: "elsewhere@example.com")
      other_event = create(:event)
      Invitation.create!(event: other_event, email: "elsewhere@example.com").mark_sent!
      pe = create(:participant_event, participant: participant, event: event, status: :invited)

      expect(message_for("all_attendees").recipients).not_to include(pe)
    end

    it "still carries everyone who has started, and still omits withdrawn and rejected" do
      started = create(:participant_event, event: event, status: :in_progress)
      awaiting = create(:participant_event, event: event, status: :awaiting_guardian)
      done = create(:participant_event, event: event, status: :complete)
      withdrawn = create(:participant_event, event: event, status: :withdrawn)
      rejected = create(:participant_event, event: event, status: :rejected)

      recipients = message_for("all_attendees").recipients

      expect(recipients).to include(started, awaiting, done)
      expect(recipients).not_to include(withdrawn, rejected)
    end

    it "counts each recipient once" do
      pe = invite!("counted@example.com")
      create(:participant_event, event: event, status: :complete)

      message = message_for("all_attendees")
      expect(message.recipient_count_estimate).to eq(2)
      expect(message.recipients.to_a).to include(pe)
    end

    it "narrows to a group when one is set, held invitees included in neither case" do
      group = event.groups.create!(name: "Bus A")
      in_group = invite!("grouped@example.com")
      GroupMembership.create!(group: group, participant_event: in_group)
      held_in_group = invite!("grouped-held@example.com", sent: false)
      GroupMembership.create!(group: group, participant_event: held_in_group)
      ungrouped = invite!("ungrouped@example.com")

      message = message_for("all_attendees")
      message.audience_filters = { "group_ids" => [ group.id ] }

      expect(message.recipients).to include(in_group)
      expect(message.recipients).not_to include(held_in_group, ungrouped)
    end
  end

  describe "#recipients for all_attendees_and_held" do
    it "adds held invitees to everyone all_attendees reaches" do
      held = invite!("held@example.com", sent: false)
      notified = invite!("notified@example.com")
      done = create(:participant_event, event: event, status: :complete)

      expect(message_for("all_attendees_and_held").recipients).to include(held, notified, done)
    end

    it "still omits withdrawn and rejected, and invitees with no invitation" do
      withdrawn = create(:participant_event, event: event, status: :withdrawn)
      rejected = create(:participant_event, event: event, status: :rejected)
      uninvited = create(:participant_event, event: event, status: :invited)

      expect(message_for("all_attendees_and_held").recipients).not_to include(withdrawn, rejected, uninvited)
    end

    it "ignores a held invitation for a different event" do
      participant = create(:participant, email: "elsewhere@example.com")
      Invitation.create!(event: create(:event), email: "elsewhere@example.com")
      pe = create(:participant_event, participant: participant, event: event, status: :invited)

      expect(message_for("all_attendees_and_held").recipients).not_to include(pe)
    end

    it "counts each recipient once" do
      invite!("held@example.com", sent: false)
      invite!("notified@example.com")

      expect(message_for("all_attendees_and_held").recipient_count_estimate).to eq(2)
    end
  end

  describe "#recipients for attendees_incomplete" do
    it "reaches a held invitee, which all_attendees deliberately will not" do
      pe = invite!("chase@example.com", sent: false)

      expect(message_for("attendees_incomplete").recipients).to include(pe)
      expect(message_for("all_attendees").recipients).not_to include(pe)
    end
  end

  describe "#send!" do
    it "creates a pending delivery per reachable channel and stamps the send" do
      reachable = create(:participant_event, event: event, status: :complete)
      no_phone = create(:participant_event, event: event, status: :complete,
        participant: create(:participant, phone: nil))
      message = message_for("confirmed_attendees")
      message.update!(channels: %w[email sms], body: "<p>Hi</p>")

      expect { expect(message.send!).to be(true) }.to have_enqueued_job(MessageDeliveryJob)

      expect(message.reload).to be_sending
      expect(message.sent_at).to be_present
      expect(message.message_deliveries.where(participant_event: reachable).pluck(:channel)).to contain_exactly("email", "sms")
      expect(message.message_deliveries.where(participant_event: no_phone).pluck(:channel)).to contain_exactly("email")
      expect(message.recipient_count).to eq(2)
    end

    it "does nothing for a message that has already gone out" do
      create(:participant_event, event: event, status: :complete)
      message = message_for("confirmed_attendees")
      message.update!(body: "<p>Hi</p>")
      message.send!

      expect { expect(message.send!).to be(false) }.not_to change(MessageDelivery, :count)
    end

    it "creates push deliveries only for participants with a registered device" do
      with_device = create(:participant_event, event: event, status: :complete,
        participant: create(:participant, user: user_with_device))
      # An app account alone isn't enough: SingleDeliveryJob needs an Expo token.
      create(:participant_event, event: event, status: :complete,
        participant: create(:participant, user: create(:user)))
      create(:participant_event, event: event, status: :complete)
      message = message_for("confirmed_attendees")
      message.update!(channels: %w[push], body: "<p>Hi</p>")

      message.send!

      expect(message.message_deliveries.pluck(:participant_event_id)).to eq([ with_device.id ])
      expect(message.recipient_count).to eq(1)
    end

    it "inserts deliveries in batches without a query per row" do
      3.times { create(:participant_event, event: event, status: :complete) }
      message = message_for("confirmed_attendees")
      message.update!(channels: %w[email sms], body: "<p>Hi</p>")

      inserts = count_queries(/INSERT INTO "message_deliveries"/) { message.send! }

      expect(inserts).to eq(1)
      expect(message.message_deliveries.count).to eq(6)
      expect(message.message_deliveries.where(catch_up: true)).to be_empty
    end

    it "stamps rows it inserts directly with the same fields a created row gets" do
      pe = create(:participant_event, event: event, status: :complete,
        participant: create(:participant, slack_user_id: "U0FAKE1"))
      message = message_for("confirmed_attendees")
      message.update!(channels: %w[slack], body: "<p>Hi</p>")

      message.send!

      delivery = message.message_deliveries.sole
      expect(delivery).to have_attributes(
        participant_event_id: pe.id, channel: "slack", status: "pending", catch_up: false,
        recipient_email: pe.participant.email, recipient_phone: pe.participant.phone, recipient_slack_id: "U0FAKE1"
      )
      expect(delivery.created_at).to be_present
      expect(delivery).to be_valid
    end
  end

  def user_with_device
    create(:user).tap do |user|
      PushToken.create!(user: user, token: "ExponentPushToken[#{SecureRandom.hex(8)}]", platform: "expo")
    end
  end

  def count_queries(pattern)
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      count += 1 if payload[:sql].match?(pattern)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe "#new_recipients and #send_to_new_recipients!" do
    # A message that went out and settled, which is the state a catch-up
    # send requires.
    def sent_message(audience, channels: %w[email], status: :completed)
      message_for(audience).tap do |message|
        message.update!(channels: channels, body: "<p>Hi</p>")
        message.send!
        message.update!(status: status)
      end
    end

    it "picks up attendees who joined the audience after the send, once" do
      original = create(:participant_event, event: event, status: :complete)
      message = sent_message("confirmed_attendees")
      latecomer = create(:participant_event, event: event, status: :in_progress)
      latecomer.update!(status: :complete)

      expect(message.new_recipients).to contain_exactly(latecomer)

      expect { expect(message.send_to_new_recipients!).to eq(1) }.to have_enqueued_job(MessageDeliveryJob)
      expect(message.message_deliveries.where(participant_event: original).count).to eq(1)
      expect(message.message_deliveries.where(participant_event: latecomer).count).to eq(1)
      expect(message.reload.recipient_count).to eq(2)

      expect(message.new_recipients).to be_empty
      expect { expect(message.send_to_new_recipients!).to eq(0) }.not_to have_enqueued_job(MessageDeliveryJob)
    end

    it "enqueues delivery for the rows it created only, flagged as catch-up" do
      create(:participant_event, event: event, status: :complete)
      message = sent_message("confirmed_attendees")
      # The original row is still pending, as if its job had not run yet; a
      # catch-up must not hand it to the fan-out job a second time.
      original = message.message_deliveries.sole
      latecomer = create(:participant_event, event: event, status: :complete)

      expect { message.send_to_new_recipients! }
        .to have_enqueued_job(MessageDeliveryJob).with { |message_id:, delivery_ids:|
          expect(message_id).to eq(message.id)
          expect(delivery_ids).to contain_exactly(message.message_deliveries.find_by!(participant_event: latecomer).id)
        }

      expect(original.reload).not_to be_catch_up
      expect(message.message_deliveries.find_by!(participant_event: latecomer)).to be_catch_up
    end

    it "refuses while the message is still draft, scheduled, sending, or cancelled" do
      create(:participant_event, event: event, status: :complete)

      %i[draft scheduled cancelled].each do |status|
        message = message_for("confirmed_attendees")
        message.update!(body: "<p>Hi</p>", status: status)
        expect(message).not_to be_can_send_to_new_recipients
        expect { expect(message.send_to_new_recipients!).to eq(0) }.not_to change(MessageDelivery, :count)
      end

      still_sending = sent_message("confirmed_attendees", status: :sending)
      create(:participant_event, event: event, status: :complete)
      expect(still_sending).not_to be_can_send_to_new_recipients
      expect { expect(still_sending.send_to_new_recipients!).to eq(0) }.not_to change(MessageDelivery, :count)
    end

    it "allows a catch-up once the message has completed or failed" do
      create(:participant_event, event: event, status: :complete)

      expect(sent_message("confirmed_attendees", status: :completed)).to be_can_send_to_new_recipients
      expect(sent_message("confirmed_attendees", status: :failed)).to be_can_send_to_new_recipients
    end

    it "re-checks the state under the lock, not just before it" do
      create(:participant_event, event: event, status: :complete)
      message = sent_message("confirmed_attendees")
      create(:participant_event, event: event, status: :complete)
      # Another process flips it back to sending between the caller's check
      # and the lock, e.g. a "retry failed" landing at the same moment.
      Message.where(id: message.id).update_all(status: "sending")

      expect(message).to be_can_send_to_new_recipients
      expect { expect(message.send_to_new_recipients!).to eq(0) }.not_to change(MessageDelivery, :count)
    end

    it "skips anyone already reached on another channel" do
      pe = create(:participant_event, event: event, status: :complete)
      message = sent_message("confirmed_attendees", channels: %w[email slack])
      pe.participant.update!(slack_user_id: "U123")

      # They have an email delivery, so linking Slack afterwards doesn't
      # earn them a second copy.
      expect(message.new_recipients).to be_empty
    end

    it "picks up someone who had no reachable channel at send time" do
      pe = create(:participant_event, event: event, status: :complete)
      message = sent_message("confirmed_attendees", channels: %w[slack])
      expect(message.message_deliveries).to be_empty

      pe.participant.update!(slack_user_id: "U123")

      expect(message.new_recipients).to contain_exactly(pe)
    end

    it "leaves out anyone the message's channels can't reach" do
      create(:participant_event, event: event, status: :complete)
      message = sent_message("confirmed_attendees", channels: %w[slack sms])
      no_slack_no_phone = create(:participant_event, event: event, status: :complete,
        participant: create(:participant, phone: nil))
      blank_phone = create(:participant_event, event: event, status: :complete,
        participant: create(:participant, phone: ""))
      with_phone = create(:participant_event, event: event, status: :complete)

      # Counting them would offer a button that sends nothing and never goes away.
      expect(message.new_recipients).to contain_exactly(with_phone)
      expect(message.new_recipients).not_to include(no_slack_no_phone, blank_phone)
      expect(message.send_to_new_recipients!).to eq(1)
    end

    it "counts push recipients only when their user has a device, in SQL and in Ruby alike" do
      create(:participant_event, event: event, status: :complete)
      message = sent_message("confirmed_attendees", channels: %w[push])
      with_device = create(:participant_event, event: event, status: :complete,
        participant: create(:participant, user: user_with_device))
      create(:participant_event, event: event, status: :complete,
        participant: create(:participant, user: create(:user)))

      expect(message.new_recipients).to contain_exactly(with_device)
      expect(message.send_to_new_recipients!).to eq(1)
      expect(message.message_deliveries.pluck(:participant_event_id)).to eq([ with_device.id ])
    end

    it "only reaches guardians by email and SMS" do
      message = sent_message("all_guardians", channels: %w[slack push])
      create(:guardian_participant_event, participant_event: create(:participant_event, event: event))

      expect(message.new_recipients).to be_empty
    end

    it "works for guardian audiences" do
      first = create(:guardian_participant_event, participant_event: create(:participant_event, event: event))
      message = sent_message("all_guardians")
      later = create(:guardian_participant_event, participant_event: create(:participant_event, event: event))

      expect(message.new_recipients).to contain_exactly(later.guardian)
      expect(message.new_recipients).not_to include(first.guardian)
    end

    it "leaves the status for the delivery jobs to settle" do
      create(:participant_event, event: event, status: :complete)
      message = sent_message("confirmed_attendees")
      message.update!(status: :completed)
      create(:participant_event, event: event, status: :complete)

      message.send_to_new_recipients!

      expect(message.reload).to be_completed
    end
  end
end
