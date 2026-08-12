module Support
  module Tickets
    class NotesController < Admin::BaseController
      before_action :set_ticket
      after_action :verify_authorized

      def create
        @note = @ticket.notes.build(note_params.merge(
          author_user_id: current_user.id,
          event_id: @ticket.event_id
        ))
        # Tickets are global (Current.event is nil here), so NotePolicy's
        # event-based checks don't apply; anyone who can work the ticket can note it.
        authorize @ticket, :update?

        if @note.save
          respond_to do |format|
            format.turbo_stream
            format.html { redirect_to support_ticket_path(@ticket), notice: "Note added." }
          end
        else
          respond_to do |format|
            format.turbo_stream { render :error }
            format.html { redirect_to support_ticket_path(@ticket), alert: "Failed to add note." }
          end
        end
      end

      def destroy
        @note = @ticket.notes.find(params[:id])
        authorize @ticket, :update?

        unless can_remove_note?(@note)
          return redirect_to support_ticket_path(@ticket), alert: "You can only remove your own notes."
        end

        @note.destroy!

        respond_to do |format|
          format.turbo_stream { render turbo_stream: turbo_stream.remove(@note) }
          format.html { redirect_to support_ticket_path(@ticket), notice: "Note removed." }
        end
      end

      private

      def set_ticket
        @ticket = Ticket.find(params[:ticket_id])
      end

      # Mirrors NotePolicy#can_edit? but keyed off the ticket's event instead of
      # Current.event, which is nil in the support flow.
      def can_remove_note?(note)
        return true if current_user.global_admin?
        return true if note.author_user_id == current_user.id

        @ticket.event.present? && current_user.event_admin_for?(@ticket.event)
      end

      def note_params
        params.require(:note).permit(:body, :note_type, :sensitivity, visible_to_roles: [])
      end
    end
  end
end
