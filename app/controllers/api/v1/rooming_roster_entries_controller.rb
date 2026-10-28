module Api
  module V1
    # The roster for a list-only stay: who's staying, and why. Built for a shop that sells the night: on
    # purchase it POSTs the buyer's email with the matching eligibility option
    # and its order id; on refund it DELETEs the entry. Adding someone who's
    # already listed updates their entry instead of failing, so a retried
    # webhook is harmless.
    class RoomingRosterEntriesController < BaseController
      include RoomingStayAccess
      include Api::V1::ApiAuditing

      before_action :set_stay
      before_action :require_roster_stay

      def index
        entries = @stay.roster_entries.includes(:eligibility_option).order(:created_at)
        entries = entries.where(external_reference: params[:external_reference]) if params[:external_reference].present?
        entries = entries.where(participant_event_id: params[:participant_event_id]) if params[:participant_event_id].present?

        render json: { roster: entries.map { |entry| entry_json(entry) } }
      end

      def create
        participant_event = find_registration
        return render_error("No registration for that person at this event", status: :not_found) unless participant_event

        option = find_option
        return if performed?

        entry, created = Rooming::Roster.new(@stay, added_by: current_user).add(
          participant_event,
          source: :api,
          option: option,
          external_reference: params[:external_reference],
          notes: params[:notes]
        )

        audit_api_change!(created ? :record_create : :record_update, entry) if created || entry.saved_changes?
        render json: entry_json(entry), status: created ? :created : :ok
      rescue ActiveRecord::RecordInvalid => e
        render_error(e.record.errors.full_messages.to_sentence)
      end

      def destroy
        entry = @stay.roster_entries.find(params[:id])
        entry.destroy!
        audit_api_change!(:record_destroy, entry, changed_fields: {})

        head :no_content
      end

      private

      def set_stay
        @stay = @event.rooming_contexts.find(params[:stay_id])
      end

      def require_roster_stay
        return if @stay.eligible_only?

        render_error("#{@stay.name} includes everyone with accommodation, so it has no roster")
      end

      # By participant_event_id when the caller has it, otherwise by email.
      def find_registration
        if params[:participant_event_id].present?
          @event.participant_events.find_by(id: params[:participant_event_id])
        elsif params[:email].present?
          Rooming::Roster.new(@stay).registration_for_email(params[:email])
        end
      end

      # By id, or by label so a shop can be configured with the words an
      # organizer typed. No option is fine; an unknown one is an error.
      def find_option
        if params[:eligibility_option_id].present?
          @stay.eligibility_options.find_by(id: params[:eligibility_option_id]) || unknown_option
        elsif params[:eligibility_option].present?
          @stay.eligibility_options.find_by("LOWER(label) = ?", params[:eligibility_option].to_s.strip.downcase) || unknown_option
        end
      end

      def unknown_option
        labels = @stay.eligibility_options.map(&:label)
        render_error("Unknown eligibility option. This stay's options are: #{labels.presence&.join(', ') || 'none'}")
        nil
      end

      def entry_json(entry)
        {
          id: entry.id,
          stay_id: entry.rooming_context_id,
          participant_event_id: entry.participant_event_id,
          eligibility_option: entry.eligibility_option && option_json(entry.eligibility_option),
          source: entry.source,
          external_reference: entry.external_reference,
          notes: entry.notes,
          in_rooming_pool: @stay.participant_events.exists?(id: entry.participant_event_id),
          created_at: entry.created_at
        }
      end
    end
  end
end
