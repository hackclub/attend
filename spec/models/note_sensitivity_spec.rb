require "rails_helper"

RSpec.describe "Note sensitivity" do
  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }
  let(:author) { create(:user) }

  let!(:normal_note) do
    Note.create!(event: event, participant_event: participant_event, author: author,
      body: "normal", note_type: "ops", visible_to_roles: %w[ops event_admin])
  end
  let!(:restricted_note) do
    Note.create!(event: event, participant_event: participant_event, author: author,
      body: "restricted", note_type: "ops", sensitivity: "restricted", visible_to_roles: %w[ops])
  end

  def user_with_role(role)
    create(:user).tap { |u| create(:event_role_assignment, user: u, event: event, role: role) }
  end

  let(:global_admin) { create(:user, global_role: "global_admin") }

  around do |example|
    Current.set(event: event) { example.run }
  end

  describe ".restricted_visible_to?" do
    it "allows global admins, event admins and safeguarding leads" do
      expect(Note.restricted_visible_to?(global_admin, event)).to be true
      expect(Note.restricted_visible_to?(user_with_role("event_admin"), event)).to be true
      expect(Note.restricted_visible_to?(user_with_role("safeguarding_lead"), event)).to be true
    end

    it "denies other roles and other events" do
      expect(Note.restricted_visible_to?(user_with_role("ops"), event)).to be false
      expect(Note.restricted_visible_to?(user_with_role("limited"), event)).to be false
      expect(Note.restricted_visible_to?(user_with_role("event_admin"), create(:event))).to be false
      expect(Note.restricted_visible_to?(nil, event)).to be false
    end
  end

  describe ".sensitivity_visible_to" do
    it "hides restricted notes from ops" do
      expect(Note.sensitivity_visible_to(user_with_role("ops"), event)).to contain_exactly(normal_note)
    end

    it "shows restricted notes to event admins" do
      expect(Note.sensitivity_visible_to(user_with_role("event_admin"), event))
        .to contain_exactly(normal_note, restricted_note)
    end
  end

  describe NotePolicy do
    it "lets event admins and safeguarding leads read restricted notes regardless of visible_to_roles" do
      %w[event_admin safeguarding_lead].each do |role|
        user = user_with_role(role)
        expect(NotePolicy.new(user, restricted_note).show?).to be(true), role
        expect(NotePolicy::Scope.new(user, Note).resolve).to include(restricted_note)
      end
    end

    it "hides restricted notes from ops even when visible_to_roles names them" do
      ops = user_with_role("ops")
      expect(NotePolicy.new(ops, restricted_note).show?).to be false
      expect(NotePolicy::Scope.new(ops, Note).resolve).to contain_exactly(normal_note)
    end

    it "stops ops creating restricted notes" do
      ops = user_with_role("ops")
      expect(NotePolicy.new(ops, Note.new(event: event, sensitivity: "restricted")).create?).to be false
      expect(NotePolicy.new(ops, Note.new(event: event)).create?).to be true
    end

    describe "note_type and visible_to_roles" do
      def note(**attrs)
        Note.create!({ event: event, participant_event: participant_event, author: author,
          body: "x", note_type: "ops" }.merge(attrs))
      end

      it "treats empty visible_to_roles as the whole event team" do
        open_note = note(visible_to_roles: [])
        %w[ops limited event_admin].each do |role|
          user = user_with_role(role)
          expect(NotePolicy.new(user, open_note).show?).to be(true), role
          expect(NotePolicy::Scope.new(user, Note).resolve).to include(open_note)
        end
      end

      it "limits targeted notes to the named roles plus safeguarding leads" do
        ops_only = note(visible_to_roles: %w[ops])
        %w[limited event_admin].each do |role|
          user = user_with_role(role)
          expect(NotePolicy.new(user, ops_only).show?).to be(false), role
          expect(NotePolicy::Scope.new(user, Note).resolve).not_to include(ops_only)
        end
        expect(NotePolicy::Scope.new(user_with_role("ops"), Note).resolve).to include(ops_only)
        expect(NotePolicy::Scope.new(user_with_role("safeguarding_lead"), Note).resolve).to include(ops_only)
      end

      it "hides safeguarding notes from everyone but safeguarding leads" do
        sg = note(note_type: "safeguarding", visible_to_roles: [])
        %w[ops limited event_admin].each do |role|
          user = user_with_role(role)
          expect(NotePolicy.new(user, sg).show?).to be(false), role
          expect(NotePolicy::Scope.new(user, Note).resolve).not_to include(sg)
        end
        expect(NotePolicy::Scope.new(user_with_role("safeguarding_lead"), Note).resolve).to include(sg)
      end

      it "treats series members as event admins" do
        series = create(:event_series)
        event.update!(event_series: series)
        member = create(:user)
        series.series_role_assignments.create!(user: member, role: "organizer")
        admins_only = note(visible_to_roles: %w[event_admin])
        expect(NotePolicy::Scope.new(member, Note).resolve).to include(admins_only, restricted_note)
        expect(NotePolicy.new(member, restricted_note).show?).to be true
      end

      it "drops blanks and rejects unknown roles" do
        expect(note(visible_to_roles: [ "", "ops" ]).visible_to_roles).to eq(%w[ops])
        bad = Note.new(event: event, author: author, body: "x", visible_to_roles: %w[wizard])
        expect(bad).not_to be_valid
      end
    end

    it "keeps restricted safeguarding notes away from event admins who aren't safeguarding leads" do
      note = Note.create!(event: event, participant_event: participant_event, author: author,
        body: "sg", note_type: "safeguarding", sensitivity: "restricted")
      expect(NotePolicy.new(user_with_role("event_admin"), note).show?).to be false
      expect(NotePolicy.new(user_with_role("safeguarding_lead"), note).show?).to be true
    end
  end
end
