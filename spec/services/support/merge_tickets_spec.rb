require "rails_helper"

RSpec.describe Support::MergeTickets do
  let(:user) { User.create!(email: "merger@example.com", name: "Support Staffer") }
  let(:phone) { "+14155559876" }

  def make_ticket(status: "open", **attrs)
    Ticket.create!(phone_number: phone, channel: "sms", status: status, **attrs)
  end

  def add_message(ticket, body, direction: "inbound")
    TicketMessage.create!(ticket: ticket, direction: direction, channel: "sms", body: body)
  end

  def merge!(source:, target:)
    described_class.call(source: source, target: target, user: user)
  end

  it "moves the source's messages onto the target, stamped with where they came from" do
    target = make_ticket(status: "closed", closed_at: 1.day.ago)
    source = make_ticket
    add_message(target, "First question")
    moved = add_message(source, "Another question")

    result = merge!(source: source, target: target)

    expect(result.moved_messages).to eq(1)
    expect(target.ticket_messages.order(:created_at).map(&:body)).to eq([ "First question", "Another question" ])
    expect(source.ticket_messages).to be_empty
    expect(moved.reload.merged_from_ticket_id).to eq(source.id)
  end

  it "closes the source and points it at the target" do
    target = make_ticket
    source = make_ticket

    merge!(source: source, target: target)

    expect(source.reload).to be_closed
    expect(source.merged_into).to eq(target)
    expect(source.merged_by).to eq(user)
    expect(source.merged_at).to be_present
    expect(target.reload.merged_tickets).to include(source)
  end

  it "reopens a closed target when the ticket merged in is still open" do
    target = make_ticket(status: "closed", closed_at: 2.days.ago, closed_by: user)
    source = make_ticket

    result = merge!(source: source, target: target)

    expect(result.reopened).to be(true)
    expect(target.reload).to be_open
    expect(target.closed_at).to be_nil
    expect(target.closed_by).to be_nil
  end

  it "leaves a closed target closed when the ticket merged in is also closed" do
    target = make_ticket(status: "closed", closed_at: 2.days.ago)
    source = make_ticket(status: "closed", closed_at: 1.day.ago)

    result = merge!(source: source, target: target)

    expect(result.reopened).to be(false)
    expect(target.reload).to be_closed
  end

  it "moves the source's notes across" do
    target = make_ticket
    source = make_ticket
    source.notes.create!(author_user_id: user.id, body: "Called them back", note_type: "ops")

    result = merge!(source: source, target: target)

    expect(result.moved_notes).to eq(1)
    expect(target.reload.notes.map(&:body)).to include("Called them back")
    expect(source.reload.notes).to be_empty
  end

  it "records the merge as a note on the target" do
    target = make_ticket
    source = make_ticket
    add_message(source, "Hello again")

    merge!(source: source, target: target)

    expect(target.reload.notes.map(&:body)).to include(a_string_matching(/Merged ticket ##{source.id[0..7]}/))
  end

  it "fills in context the target is missing without overwriting its own" do
    event = create(:event)
    other_event = create(:event)
    target = make_ticket
    source = make_ticket(event: event, assigned_to: user)

    merge!(source: source, target: target)
    expect(target.reload.event).to eq(event)
    expect(target.assigned_to).to eq(user)

    second_source = make_ticket(event: other_event)
    merge!(source: second_source, target: target)
    expect(target.reload.event).to eq(event)
  end

  it "carries the latest activity timestamps onto the target" do
    target = make_ticket(status: "closed", last_message_at: 3.days.ago, last_inbound_at: 3.days.ago)
    source = make_ticket(last_message_at: 1.hour.ago, last_inbound_at: 1.hour.ago)

    merge!(source: source, target: target)

    expect(target.reload.last_message_at).to be_within(1.second).of(source.last_message_at)
  end

  it "refuses to merge a ticket into itself" do
    ticket = make_ticket

    expect { merge!(source: ticket, target: ticket) }.to raise_error(described_class::MergeError, /itself/)
  end

  it "refuses to merge tickets with different phone numbers" do
    target = make_ticket
    source = Ticket.create!(phone_number: "+14155550000", channel: "sms", status: "open")

    expect { merge!(source: source, target: target) }.to raise_error(described_class::MergeError, /same phone number/)
  end

  it "refuses to merge a ticket that was already merged elsewhere" do
    target = make_ticket
    other = make_ticket
    source = make_ticket
    merge!(source: source, target: other)

    expect { merge!(source: source, target: target) }.to raise_error(described_class::MergeError, /already merged/)
  end

  it "points at the surviving ticket when the target has itself been merged away" do
    survivor = make_ticket
    target = make_ticket
    source = make_ticket
    merge!(source: target, target: survivor)

    expect { merge!(source: source, target: target) }
      .to raise_error(described_class::MergeError, /merge into that ticket instead/)
  end

  describe "after merging" do
    it "keeps the merged ticket out of the inbox and out of inbound matching" do
      target = make_ticket(status: "closed")
      source = make_ticket
      merge!(source: source, target: target)

      expect(Ticket.unmerged).not_to include(source)

      Support::ProcessIncomingTwilioMessage.call(
        "From" => phone, "To" => "+18005550100", "Body" => "Still there?", "MessageSid" => "SM999", "NumMedia" => "0"
      )

      expect(source.reload.ticket_messages).to be_empty
    end

    it "refuses to send a reply on the merged ticket" do
      target = make_ticket
      source = make_ticket
      merge!(source: source, target: target)

      expect { Support::SendTicketMessage.call(ticket: source.reload, body: "Hi", user: user) }
        .to raise_error(Support::SendTicketMessage::DeliveryError, /merged into/)
    end

    it "resolves the chain of merges to the ticket holding the thread" do
      survivor = make_ticket
      middle = make_ticket
      source = make_ticket

      merge!(source: source, target: middle)
      merge!(source: middle, target: survivor)

      expect(source.reload.merge_root).to eq(survivor)
    end
  end
end
