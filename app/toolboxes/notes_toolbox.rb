class NotesToolbox < ApplicationToolbox
  # Notes on a participant's registration. Visibility follows note_type / sensitivity
  # / visible_to_roles and the reader's event role (enforced by NotePolicy).

  tool "List notes on a participant registration that you're permitted to see.",
    access: :read, scope: "participants:read" do
    param :participant_event_id, :string, "ParticipantEvent ID"
  end
  def index
    @participant_event = ParticipantEvent.find(params[:participant_event_id])
    Current.event = @participant_event.event
    authorize! @participant_event, :view_notes?
    notes = policy_scope(@participant_event.notes).order(created_at: :desc)
    render json: { participant_event_id: @participant_event.id, notes: notes.map { |n| serialize_note(n) } }
  end

  tool "Add a note to a participant registration.", access: :write, scope: "participants:write" do
    param :participant_event_id, :string, "ParticipantEvent ID"
    param :body, :string, "Note text"
    param :note_type, :string, "Note type", enum: %w[ops safeguarding logistical], optional: true
    param :sensitivity, :string, "Sensitivity", enum: %w[normal restricted], optional: true
    param :visible_to_roles, [ :string ], "Roles that may see this note", optional: true
  end
  def create
    @participant_event = ParticipantEvent.find(params[:participant_event_id])
    Current.event = @participant_event.event
    @note = @participant_event.notes.build(
      params.permit(:body, :note_type, :sensitivity, visible_to_roles: []).to_h
    )
    @note.event = @participant_event.event
    @note.author = current_user
    authorize! @note, :create?
    @note.save!
    render json: serialize_note(@note)
  end

  private

  def serialize_note(n)
    { id: n.id, body: n.body, note_type: n.note_type, sensitivity: n.sensitivity,
      visible_to_roles: n.visible_to_roles, author: n.author&.display_name_or_fallback, at: n.created_at }
  end
end
