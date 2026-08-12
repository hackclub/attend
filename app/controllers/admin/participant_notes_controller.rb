module Admin
  class ParticipantNotesController < BaseController
    before_action :require_event_selected
    before_action :set_participant_event
    before_action :set_note, only: [ :destroy ]

    def create
      @note = @participant_event.notes.build(note_params)
      @note.event = current_event
      @note.author = current_user

      if @note.save
        redirect_to admin_event_participant_path(current_event, @participant_event), notice: "Note added successfully."
      else
        redirect_to admin_event_participant_path(current_event, @participant_event), alert: "Failed to add note: #{@note.errors.full_messages.join(', ')}"
      end
    end

    def destroy
      unless can_delete_note?(@note)
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
      @note = @participant_event.notes.find(params[:id])
    end

    def note_params
      params.require(:note).permit(:body, :note_type, :sensitivity, visible_to_roles: [])
    end

    def can_delete_note?(note)
      return true if current_user.global_admin?
      return true if note.author == current_user

      current_user.event_admin_for?(current_event)
    end
  end
end
