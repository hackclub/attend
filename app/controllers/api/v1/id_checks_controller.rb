module Api
  module V1
    # Records the outcome of an on-device ID document check. The phone reads the
    # passport or ID card chip, verifies it and compares it with the participant;
    # only the outcome comes here. The permitted fields below are an allowlist on
    # purpose: no document number, MRZ, name, date of birth or photo may ever be
    # accepted, whatever a future app build sends.
    class IdChecksController < BaseController
      include Pundit::Authorization

      before_action :reject_api_key_auth
      before_action -> { require_global_admin!("Only global admins can record ID checks") }
      before_action :set_event
      before_action :set_participant_event
      before_action :set_paper_trail_whodunnit

      VERDICTS = %w[confirmed rejected].freeze
      RESULTS = %w[green amber red].freeze
      PERMITTED = %i[
        verdict result document_type issuing_state
        data_integrity issuer active_auth chip_auth access_protocol
        name_match dob_match expired
      ].freeze

      def create
        attrs = id_check_params
        unless VERDICTS.include?(attrs[:verdict]) && RESULTS.include?(attrs[:result])
          return render_error("Invalid verdict or result")
        end
        # A red result is a failed check: it can be recorded, but only as a rejection.
        if attrs[:result] == "red" && attrs[:verdict] == "confirmed"
          return render_error("A red result can only be recorded as rejected")
        end

        note = nil
        ActiveRecord::Base.transaction do
          note = @participant_event.notes.create!(
            event: @event,
            author: current_user,
            note_type: "safeguarding",
            sensitivity: "normal",
            body: note_body(attrs)
          )
          AuditLog.log!(
            action: :id_check,
            record: @participant_event,
            actor: current_user,
            event: @event,
            metadata: attrs.merge(note_id: note.id)
          )
        end

        render json: { note_id: note.id }, status: :created
      end

      private

      def id_check_params
        attrs = params.require(:id_check).permit(*PERMITTED).to_h.symbolize_keys
        %i[dob_match expired].each do |key|
          attrs[key] = ActiveModel::Type::Boolean.new.cast(attrs[key]) if attrs.key?(key)
        end
        attrs
      end

      # Same as NotesController: the note and audit row are attributed to a person.
      def reject_api_key_auth
        return unless api_key_request?
        render json: { error: "API key is not authorized for ID checks" }, status: :forbidden
      end

      def set_event
        @event = Event.find(params[:event_id])
        Current.event = @event
        authorize @event, :api_participants?
      end

      def set_participant_event
        @participant_event = @event.participant_events.find(params[:participant_id])
      end

      # Api::V1::BaseController doesn't get ApplicationController's PaperTrail
      # hook, so the note's first version would otherwise have no author.
      def set_paper_trail_whodunnit
        PaperTrail.request.whodunnit = current_user.id
      end

      def note_body(a)
        chip = a[:data_integrity] == "valid" && a[:issuer] == "valid" ? "authentic" : "issuer #{a[:issuer]}"
        "ID check #{a[:verdict]} (#{a[:result]}): #{a[:issuing_state]} #{doc_label(a[:document_type])}. " \
          "Chip #{chip}, name #{a[:name_match]}, DOB #{a[:dob_match] ? 'match' : 'mismatch'}" \
          "#{a[:expired] ? ', expired' : ''}."
      end

      def doc_label(type)
        { "P" => "passport" }.fetch(type, "ID card")
      end
    end
  end
end
