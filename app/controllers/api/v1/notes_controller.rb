module Api
  module V1
    class NotesController < BaseController
      include Pundit::Authorization

      before_action :reject_api_key_auth
      before_action :set_event
      before_action :set_participant_event

      def index
        notes = @participant_event.notes
          .includes(:author)
          .order(created_at: :desc)

        render json: {
          notes: notes.map { |note| note_json(note) }
        }
      end

      def create
        note = @participant_event.notes.build(
          body: params[:content],
          event: @event,
          author: current_user,
          note_type: params[:note_type] || "ops",
          sensitivity: params[:sensitivity] || "normal"
        )

        if note.save
          render json: { note: note_json(note) }, status: :created
        else
          render json: { error: note.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      private

      # Notes are attributed to their author, so every note endpoint needs a
      # person behind the request. No API key — event or series — qualifies.
      def reject_api_key_auth
        return unless api_key_request?
        render json: { error: "API key is not authorized for notes" }, status: :forbidden
      end

      def set_event
        @event = Event.find(params[:event_id])
        Current.event = @event

        if api_key_request?
          require_api_key_event_scope!(@event)
        else
          authorize @event, :api_participants?
        end
      end

      def set_participant_event
        @participant_event = @event.participant_events.find(params[:participant_id])
      end

      def note_json(note)
        {
          id: note.id,
          content: note.body,
          note_type: note.note_type,
          sensitivity: note.sensitivity,
          created_at: note.created_at.iso8601,
          author: {
            id: note.author.id,
            name: note.author.name,
            email: note.author.email
          }
        }
      end
    end
  end
end
