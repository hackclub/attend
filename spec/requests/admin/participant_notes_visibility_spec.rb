require "rails_helper"

# A registration's notes are filtered by NotePolicy::Scope: safeguarding notes
# reach only safeguarding leads, and every other note only the roles it is
# visible to. The participant record, its notes tab and the header's note
# count must agree with that scope in both the original and the console UI.
RSpec.describe "Participant notes visibility", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }
  let(:author) { User.create!(email: "notes-author-spec@example.com", name: "Author") }

  before do
    Note.create!(event: event, participant_event: participant_event, author: author,
      note_type: "safeguarding", visible_to_roles: %w[safeguarding_lead], body: "Safeguarding note body")
    Note.create!(event: event, participant_event: participant_event, author: author,
      note_type: "ops", visible_to_roles: %w[safeguarding_lead], body: "Lead-only note body")
    Note.create!(event: event, participant_event: participant_event, author: author,
      note_type: "ops", visible_to_roles: %w[limited ops], body: "Shared ops note body")
  end

  def sign_in_with_role(role, console: false)
    user = User.create!(email: "#{role}-notes-spec@example.com", name: role.titleize, admin_console_beta: console)
    EventRoleAssignment.create!(user: user, event: event, role: role)
    sign_in user
  end

  [ false, true ].each do |console|
    context(console ? "in the console UI" : "in the original UI") do
      it "hides notes outside a limited user's scope on the record and notes tab" do
        sign_in_with_role("limited", console: console)

        [ admin_event_participant_path(event.slug, participant_event),
          notes_admin_event_participant_path(event.slug, participant_event) ].each do |path|
          get path

          expect(response).to have_http_status(:ok)
          expect(response.body).not_to include("Safeguarding note body", "Lead-only note body")
          expect(response.body).to match(/Notes\s*(<[^>]+>)?\(1\)/)
        end
        expect(response.body).to include("Shared ops note body")
      end
    end
  end

  it "shows every note to a safeguarding lead" do
    sign_in_with_role("safeguarding_lead")

    get notes_admin_event_participant_path(event.slug, participant_event)

    expect(response.body).to include("Safeguarding note body", "Lead-only note body")
  end

  it "keeps out-of-scope note bodies off the history tab" do
    sign_in_with_role("limited")

    get history_admin_event_participant_path(event.slug, participant_event)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Safeguarding note body", "Lead-only note body")
  end

  describe "deleting a note" do
    let(:hidden_note) { participant_event.notes.find_by!(note_type: "safeguarding") }

    it "does not let an event admin outside the note's scope delete it" do
      sign_in_with_role("event_admin")

      delete admin_event_participant_note_path(event.slug, participant_event, hidden_note)

      expect(Note.exists?(hidden_note.id)).to be(true)
    end

    it "lets a safeguarding lead delete a safeguarding note" do
      sign_in_with_role("safeguarding_lead")

      delete admin_event_participant_note_path(event.slug, participant_event, hidden_note)

      expect(Note.exists?(hidden_note.id)).to be(false)
    end
  end
end
