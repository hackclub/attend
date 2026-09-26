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

  describe "#recipients for attendees_incomplete" do
    it "reaches a held invitee, which all_attendees deliberately will not" do
      pe = invite!("chase@example.com", sent: false)

      expect(message_for("attendees_incomplete").recipients).to include(pe)
      expect(message_for("all_attendees").recipients).not_to include(pe)
    end
  end
end
