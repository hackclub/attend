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

  describe "#scheduled_at on the event's clock" do
    let(:event) { create(:event, timezone: "Pacific Time (US & Canada)") }

    def scheduled(value)
      message_for("all_attendees").tap { |message| message.assign_attributes(body: "Hello", scheduled_at: value) }
    end

    it "reads a datetime-local value in the event's time zone" do
      message = scheduled("2030-07-12T09:30")
      message.validate

      expect(message.scheduled_at).to eq(Time.utc(2030, 7, 12, 16, 30))
      expect(message.local_time_field_value(:scheduled_at)).to eq("2030-07-12T09:30")
    end

    it "keeps a time that names its own offset" do
      message = scheduled("2030-07-12T09:30:00Z")
      message.validate

      expect(message.scheduled_at).to eq(Time.utc(2030, 7, 12, 9, 30))
    end

    it "reads it as UTC for an event with no time zone set" do
      event.update_column(:timezone, nil)
      message = scheduled("2030-07-12T09:30")
      message.validate

      expect(message.scheduled_at).to eq(Time.utc(2030, 7, 12, 9, 30))
    end

    it "forgets a datetime-local value that was replaced before validation" do
      message = scheduled("2030-07-12T09:30")
      message.scheduled_at = nil
      message.validate

      expect(message.scheduled_at).to be_nil
    end

    it "leaves a saved time alone when autosave resubmits the same field value" do
      message = scheduled("2030-07-12T09:30")
      message.save!

      message.update!(scheduled_at: message.local_time_field_value(:scheduled_at))

      expect(message.saved_changes).not_to have_key("scheduled_at")
      expect(message.reload.scheduled_at).to eq(Time.utc(2030, 7, 12, 16, 30))
    end
  end

  describe "guardian audiences" do
    it "leaves out guardians who have finished everything for guardians_pending" do
      pending_link = create(:guardian_participant_event, participant_event: create(:participant_event, event: event))
      create(:guardian_participant_event, participant_event: create(:participant_event, event: event), status: :completed)

      expect(message_for("guardians_pending").recipients).to contain_exactly(pending_link.guardian)
    end

    it "counts guardian links with no status as pending" do
      link = create(:guardian_participant_event, participant_event: create(:participant_event, event: event))
      link.update_column(:status, nil)

      expect(message_for("guardians_pending").recipients).to contain_exactly(link.guardian)
    end

    it "applies the group filter to the same child that matched the audience" do
      group = create(:group, event: event)
      guardian = create(:guardian)
      confirmed = create(:participant_event, event: event, status: :complete)
      grouped = create(:participant_event, event: event, status: :in_progress)
      GroupMembership.create!(group: group, participant_event: grouped)
      create(:guardian_participant_event, guardian: guardian, participant_event: confirmed)
      create(:guardian_participant_event, guardian: guardian, participant_event: grouped)

      message = message_for("guardians_of_confirmed")
      message.audience_filters = { "group_ids" => [ group.id ] }

      expect(message.recipients).to be_empty
    end
  end

  describe "placeholders" do
    def message_with(body, audience: "confirmed_attendees", subject: nil)
      message_for(audience).tap { |message| message.assign_attributes(body: body, subject: subject) }
    end

    def guardian_of(*participants, statuses: nil)
      create(:guardian, legal_first_name: "Pat").tap do |guardian|
        participants.each_with_index do |participant, index|
          participant_event = create(:participant_event, event: event, participant: participant,
            status: statuses ? statuses[index] : :complete)
          create(:guardian_participant_event, guardian: guardian, participant_event: participant_event)
        end
      end
    end

    it "uses a participant's preferred name, then their legal first name" do
      message = message_with("<p>Hi {{first_name}}, welcome to {{ event_name }}!</p>")

      expect(message.body_as_plain(recipient: create(:participant, legal_first_name: "Alexander", preferred_name: "Alex")))
        .to eq("Hi Alex, welcome to #{event.name}!")
      expect(message.body_as_plain(recipient: create(:participant, legal_first_name: "Sam")))
        .to eq("Hi Sam, welcome to #{event.name}!")
    end

    it "falls back to 'there' when there is no name on file" do
      participant = create(:participant, legal_first_name: Participant::NAME_PLACEHOLDER)

      expect(message_with("<p>Hi {{first_name}},</p>").body_as_plain(recipient: participant)).to eq("Hi there,")
    end

    it "fills in the subject" do
      message = message_with("<p>Hi</p>", subject: "{{first_name}}, your travel details")

      expect(message.subject_for(create(:participant, legal_first_name: "Sam"))).to eq("Sam, your travel details")
      expect(message_with("<p>Hi</p>").subject_for(create(:participant))).to be_nil
    end

    it "leaves tokens as written when there is no recipient" do
      expect(message_with("<p>Hi {{first_name}}</p>").body_as_plain).to eq("Hi {{first_name}}")
    end

    it "escapes names for each format" do
      participant = create(:participant, preferred_name: "<b>Jo</b> & Co")
      message = message_with("<p>Hi {{first_name}}</p>")

      expect(message.body_as_html(recipient: participant)).to eq("<p>Hi &lt;b&gt;Jo&lt;/b&gt; &amp; Co</p>")
      expect(message.body_as_slack(recipient: participant)).to eq("Hi &lt;b&gt;Jo&lt;/b&gt; &amp; Co")
      expect(message.body_as_plain(recipient: participant)).to eq("Hi <b>Jo</b> & Co")
    end

    it "can't turn a name into a link that runs script" do
      participant = create(:participant, preferred_name: "javascript:alert(1)")
      message = message_with("<p>x</p>")
      message.body = %(<p><a href="{{first_name}}">Hi</a></p>)

      expect(message.body_as_html(recipient: participant)).not_to include("javascript:")
    end

    it "sends plain text with entities decoded, named ones included" do
      expect(message_with("<p>Q&amp;A at 5 &lt;3</p>").body_as_plain).to eq("Q&A at 5 <3")
      expect(message_with("<p>See you&nbsp;there&hellip; it&rsquo;s on</p>").body_as_plain).to eq("See you there… it’s on")
    end

    it "never calls a participant 'your child' when their name is unknown" do
      participant = create(:participant, legal_first_name: Participant::NAME_PLACEHOLDER)
      message = message_with("<p>Hi {{participant_first_name}}</p>", audience: "all_guardians")

      expect(message.body_as_plain(recipient: participant)).to eq("Hi there")
    end

    it "only counts known placeholders as used" do
      expect(message_with("<p>Hi {{first_name}}</p>")).to be_uses_placeholders
      expect(message_with("<p>Hi</p>", subject: "{{event_name}}")).to be_uses_placeholders
      expect(message_with("<p>Use {{coupon}}</p>")).not_to be_uses_placeholders
      expect(message_with("<p>Hi</p>")).not_to be_uses_placeholders
    end

    it "renames the children when the audience changes on the same instance" do
      guardian = guardian_of(create(:participant, legal_first_name: "Alex"),
        create(:participant, legal_first_name: "Sam"),
        statuses: [ :complete, :in_progress ])
      message = message_with("<p>{{participant_first_name}}</p>", audience: "guardians_of_confirmed")

      expect(message.body_as_plain(recipient: guardian)).to eq("Alex")
      message.audience = "all_guardians"
      expect(message.body_as_plain(recipient: guardian)).to eq("Alex and Sam")
    end

    it "greets guardians by name and names the children who put them in the audience" do
      guardian = guardian_of(create(:participant, legal_first_name: "Alex"),
        create(:participant, legal_first_name: "Sam"),
        create(:participant, legal_first_name: "Robin"),
        statuses: [ :complete, :complete, :in_progress ])
      message = message_with("<p>Hi {{first_name}}, {{participant_first_name}} are all set.</p>",
        audience: "guardians_of_confirmed")

      expect(message.body_as_plain(recipient: guardian)).to eq("Hi Pat, Alex and Sam are all set.")
    end

    it "names all of a guardian's children when none match the audience any more" do
      guardian = guardian_of(create(:participant, legal_first_name: "Alex"), statuses: [ :in_progress ])
      message = message_with("<p>{{participant_first_name}}</p>", audience: "guardians_of_confirmed")

      expect(message.body_as_plain(recipient: guardian)).to eq("Alex")
    end

    describe "validation" do
      it "rejects unknown placeholders in the body or subject" do
        expect(message_with("<p>Hi {{firstname}}</p>")).not_to be_valid
        expect(message_with("<p>Hi</p>", subject: "{{name}}")).not_to be_valid
        expect(message_with("<p>Hi {{first_name}} at {{event_name}}</p>")).to be_valid
      end

      it "rejects placeholders inside a link's address" do
        expect(message_with(%(<p><a href="https://example.com/{{first_name}}">Hi</a></p>))).not_to be_valid
        expect(message_with(%(<p><a href="https://example.com">Hi {{first_name}}</a></p>))).to be_valid
      end

      it "only allows participant_first_name for guardian audiences" do
        expect(message_with("<p>{{participant_first_name}}</p>")).not_to be_valid
        expect(message_with("<p>{{participant_first_name}}</p>", audience: "all_guardians")).to be_valid
      end

      it "doesn't block status updates on messages saved before the check existed" do
        message = message_with("<p>Hi</p>")
        message.save!
        message.update_column(:body, "<p>{{legacy}}</p>")

        expect { message.reload.update!(status: :completed) }.not_to raise_error
      end
    end
  end

  describe "#body_as_plain" do
    def plain(html)
      Message.new(body: html).body_as_plain
    end

    it "keeps paragraphs apart and line breaks intact" do
      expect(plain("<p>Doors open at 9.</p>\n<p>See you there.<br>Bring snacks.</p>"))
        .to eq("Doors open at 9.\n\nSee you there.\nBring snacks.")
    end

    it "renders bullet and numbered lists, including nested ones" do
      html = "<p>Bring:</p>\n<ul>\n<li>A laptop</li>\n<li>ID\n<ul><li>passport works</li></ul></li>\n</ul>" \
             "<ol><li>first</li><li>second</li></ol>"

      expect(plain(html)).to eq("Bring:\n\n• A laptop\n• ID\n  • passport works\n\n1. first\n2. second")
    end

    it "spells out link targets and decodes entities" do
      expect(plain('<p>Read <a href="https://example.com/faq">the FAQ</a> &amp; reply</p>'))
        .to eq("Read the FAQ (https://example.com/faq) & reply")
    end

    it "doesn't repeat a link whose text is already the URL" do
      expect(plain('<a href="https://example.com">https://example.com</a>')).to eq("https://example.com")
    end

    it "handles blank and tagless bodies" do
      expect(plain("")).to eq("")
      expect(plain("just text")).to eq("just text")
    end
  end

  describe "images" do
    def upload(event_id: event.id, filename: "venue-map.png")
      ActiveStorage::Blob.create_and_upload!(io: file_fixture("headshot.png").open, filename: filename,
        metadata: { Message::IMAGE_EVENT_KEY => event_id })
    end

    def img(blob, alt: "Venue map")
      %(<img src="#{Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)}" alt="#{alt}">)
    end

    def saved_message(body)
      message_for("confirmed_attendees").tap { |message| message.update!(body: body) }
    end

    it "attaches an upload when the body that shows it is saved" do
      blob = upload
      message = saved_message("<p>Map:</p>#{img(blob)}")

      expect(message.images.blobs).to eq([ blob ])
    end

    it "doesn't attach a file that wasn't uploaded for this event's messages" do
      other_event = upload(event_id: create(:event).id)
      headshot = ActiveStorage::Blob.create_and_upload!(io: file_fixture("headshot.png").open, filename: "headshot.png")
      message = saved_message("#{img(other_event)}#{img(headshot)}")

      expect(message.images).not_to be_attached
      expect(message.body_as_html).not_to include("<img")
    end

    it "points the email at a resized copy on this app, no wider than the email" do
      blob = upload
      blob.analyze
      message = saved_message("<p>Map:</p>#{img(blob)}")

      tag = Nokogiri::HTML5.fragment(message.body_as_html).at_css("img")
      expect(tag["src"]).to start_with("http://example.com/rails/active_storage/representations/")
      expect(tag["alt"]).to eq("Venue map")
      expect(tag["width"]).to eq("1")
      expect(tag["style"]).to include("max-width: 100%")
    end

    it "sends a GIF as it is, so it keeps its animation" do
      gif = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(Vips::Image.black(4, 4).write_to_buffer(".gif")),
        filename: "wave.gif", metadata: { Message::IMAGE_EVENT_KEY => event.id })
      message = saved_message(img(gif))

      expect(Nokogiri::HTML5.fragment(message.body_as_html).at_css("img")["src"])
        .to start_with("http://example.com/rails/active_storage/blobs/")
    end

    it "drops images from other sites" do
      message = saved_message(%(<p>Hi</p><img src="https://tracker.example/pixel.gif">))

      expect(message.body_as_html).to eq("<p>Hi</p>")
    end

    it "links the image on Slack and its preview, and leaves it out of plain text" do
      blob = upload
      message = saved_message("<p>Map:</p>#{img(blob)}")

      expect(message.body_as_slack).to match(%r{<http://example\.com/rails/active_storage/representations/\S+\|Venue map>})
      expect(message.body_as_plain).to eq("Map:")
      expect(message.body_as_html(images_as_links: true))
        .to match(%r{<a href="http://example\.com/rails/active_storage/representations/[^"]+" target="_blank">Venue map</a>})
    end

    it "sends the email through the storage redirect, not the app's file proxy" do
      blob = upload
      message = saved_message(img(blob))

      expect(Nokogiri::HTML5.fragment(message.body_as_html).at_css("img")["src"])
        .to start_with("http://example.com/rails/active_storage/representations/redirect/")
    end

    it "escapes the alt text in the Slack link so it can't break out of it" do
      blob = upload
      message = saved_message(img(blob, alt: "Map | east lot &lt;!channel&gt;"))

      expect(message.body_as_slack).to match(%r{\|Map / east lot &lt;!channel&gt;>\z})
    end

    it "renders a preloaded message's images without querying for them" do
      blob = upload
      message = Message.includes(images_attachments: :blob).find(saved_message(img(blob)).id)

      queries = []
      counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { message.body_as_html }

      expect(queries.grep(/active_storage_(blobs|attachments)/)).to be_empty
    end

    it "won't save a body with an image that's still uploading" do
      message = message_for("confirmed_attendees")
      message.body = %(<p>Map:</p><img src="blob:https://attend.example/1234">)

      expect(message).not_to be_valid
      expect(message.errors[:body].first).to include("hasn't finished uploading")
    end

    describe "when the message is deleted" do
      it "removes the images of a draft that never went out" do
        blob = upload
        message = saved_message(img(blob))

        expect { message.destroy! }.to have_enqueued_job(ActiveStorage::PurgeJob).with(blob)
      end

      it "keeps the images of a message that went out, which emails already link to" do
        blob = upload
        message = saved_message(img(blob))
        message.message_deliveries.create!(participant_event: create(:participant_event, event: event),
          channel: "email", recipient_email: "someone@example.com")

        expect { message.destroy! }.not_to have_enqueued_job(ActiveStorage::PurgeJob)
      end

      it "keeps an image another message shows too" do
        blob = upload
        message = saved_message(img(blob))
        saved_message(img(blob))

        expect { message.destroy! }.not_to have_enqueued_job(ActiveStorage::PurgeJob)
      end
    end
  end
end
