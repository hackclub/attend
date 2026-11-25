module Admin
  class ParticipantNotesController < BaseController
    before_action :require_event_selected
    before_action :set_participant_event
    before_action :set_note, only: [ :destroy ]

    def create
      result = Notes::Create.call(operation_context, participant_event: @participant_event, attributes: note_params)
      @note = result.value || result.record
      participant_path = admin_event_participant_path(current_event, @participant_event)

      if result.success?
        redirect_to participant_path, notice: "Note added successfully."
      elsif result.code == :invalid
        redirect_to participant_path, alert: "Failed to add note: #{@note.errors.full_messages.join(', ')}"
      else
        redirect_to participant_path, alert: result.message
      end
    end

    def destroy
      unless policy(@note).destroy?
        redirect_to admin_event_participant_path(current_event, @participant_event), alert: "You are not authorized to delete this note."
        return
      end

      @note.destroy
      redirect_to admin_event_participant_path(current_event, @participant_event), notice: "Note deleted."
    end

    private

    def set_participant_event
      @participant_event = current_event.participant_events.find(params[:participant_id])
    end

    def set_note
      @note = policy_scope(@participant_event.notes).find(params[:id])
    end

    def note_params
      params.require(:note).permit(:body, :note_type, :sensitivity, visible_to_roles: [])
    end
  end
end
