require "rails_helper"

RSpec.describe Notes::Create do
  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }

  def staff(role)
    create(:user).tap { |user| EventRoleAssignment.create!(user: user, event: event, role: role) }
  end

  def context_for(user, surface: :html)
    Operation::Context.new(surface: surface, user: user, event: event)
  end

  around { |example| Current.set(event: event) { example.run } }

  it "adds the note as the acting user and audits it without the body" do
    author = staff("ops")

    result = described_class.call(context_for(author), participant_event: participant_event,
      attributes: { body: "Arriving a day late.", note_type: "logistical", visible_to_roles: [ "ops" ] })

    expect(result).to be_success
    note = result.value
    expect(note).to have_attributes(body: "Arriving a day late.", note_type: "logistical", author: author, event: event,
      visible_to_roles: [ "ops" ])

    log = AuditLog.sole
    expect(log.action).to eq("record_create")
    expect(log.record).to eq(note)
    expect(log.actor).to eq(author)
    expect(log.event).to eq(event)
    expect(log.changed_fields["body"]).to eq("[REDACTED]")
    expect(log.to_json).not_to include("Arriving a day late.")
  end

  it "ignores attributes a note author doesn't get to set" do
    someone_else = create(:user)

    result = described_class.call(context_for(staff("ops")), participant_event: participant_event,
      attributes: { body: "Fine.", author_user_id: someone_else.id })

    expect(result.value.author).not_to eq(someone_else)
  end

  %w[ops limited read_only].each do |role|
    it "refuses a restricted note from #{role}, by name" do
      result = described_class.call(context_for(staff(role)), participant_event: participant_event,
        attributes: { body: "Sensitive.", sensitivity: "restricted" })

      expect(result.code).to eq(:restricted_not_allowed)
      expect(Note.count).to eq(0)
      expect(AuditLog.count).to eq(0)
    end
  end

  %w[event_admin safeguarding_lead].each do |role|
    it "lets #{role} add a restricted note" do
      result = described_class.call(context_for(staff(role)), participant_event: participant_event,
        attributes: { body: "Sensitive.", sensitivity: "restricted" })

      expect(result).to be_success
      expect(result.value).to be_restricted
    end
  end

  it "refuses someone with no role on the event" do
    expect {
      described_class.call(context_for(create(:user)), participant_event: participant_event, attributes: { body: "Hello." })
    }.to raise_error(Pundit::NotAuthorizedError)
    expect(Note.count).to eq(0)
  end

  it "comes back invalid, with the note, when it can't be saved" do
    result = described_class.call(context_for(staff("ops")), participant_event: participant_event, attributes: { body: "" })

    expect(result.code).to eq(:invalid)
    expect(result.record.errors).to be_present
    expect(AuditLog.count).to eq(0)
  end
end
