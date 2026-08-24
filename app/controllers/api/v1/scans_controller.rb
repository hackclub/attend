module Api
  module V1
    class ScansController < BaseController
      include AirportPickupMarkable
      before_action :set_event
      before_action :require_event_access

      # Cap for `since` incremental syncs — a stale client cursor must not be
      # able to load the event's entire scan history in one request.
      SINCE_SYNC_LIMIT = 500

      def index
        scans = Scan.for_event(@event)
          .includes(:user, :scan_context, participant_event: :participant)
          .recent

        if params[:scan_context_id].present?
          scans = scans.where(scan_context_id: params[:scan_context_id])
        end

        if params[:since].present?
          # Oldest-first within the window so a truncated page is a resumable
          # prefix — synced_at then points at the last delivered scan and the
          # client's next poll picks up exactly where this one stopped.
          since = Time.zone.parse(params[:since])
          scans = scans.reorder(created_at: :asc)
            .where("scans.created_at > ?", since)
            .limit(SINCE_SYNC_LIMIT)
        else
          scans = scans.limit(100)
        end

        scans = scans.to_a
        truncated = params[:since].present? && scans.size == SINCE_SYNC_LIMIT

        render json: {
          scans: scans.map { |scan| scan_json(scan) },
          has_more: truncated,
          synced_at: truncated ? scans.last.created_at.iso8601(6) : Time.current.iso8601
        }
      end

      def destroy
        participant_event = @event.participant_events
          .includes(:participant, scans: :scan_context)
          .find_by(id: params[:id])

        participant_event ||= @event.participant_events
          .joins(:participant)
          .includes(:participant, scans: :scan_context)
          .find_by(participants: { id: params[:id] })

        unless participant_event
          return render json: { error: "Participant not found for this event" }, status: :not_found
        end

        scans_to_delete = if params[:scan_context_id].present?
          scan_context = @event.scan_contexts.find_by(id: params[:scan_context_id])
          unless scan_context
            return render json: { error: "Invalid scan context" }, status: :unprocessable_entity
          end
          participant_event.scans.where(scan_context: scan_context)
        else
          participant_event.scans
        end

        deleted_count = scans_to_delete.count
        context_name = params[:scan_context_id].present? ? scan_context&.name : "all contexts"

        # Deleting the scans is the whole undo — check-in state is derived from
        # them (ParticipantEvent#check_in_time).
        scans_to_delete.destroy_all

        # Audit log the undo action
        AuditLog.log!(
          action: "undo_check_in",
          record: participant_event,
          actor: current_user,
          event: @event,
          changed_fields: {},
          metadata: {
            deleted_scans: deleted_count,
            scan_context_id: params[:scan_context_id],
            scan_context_name: context_name,
            participant_name: participant_event.participant.display_name
          }
        )

        render json: {
          success: true,
          deleted_scans: deleted_count,
          participant_event_id: participant_event.id,
          scan_context_id: params[:scan_context_id]
        }
      end

      def create
        if params[:client_scan_id].present?
          existing_scan = Scan.find_by(client_scan_id: params[:client_scan_id])
          if existing_scan
            return render json: {
              success: true,
              scan: scan_json(existing_scan),
              participant: participant_detail_json(existing_scan.participant_event),
              deduplicated: true
            }
          end
        end

        scan_contexts = @event.scan_contexts.to_a

        if scan_contexts.empty?
          return render json: { error: "No scan context configured for this event" }, status: :unprocessable_entity
        end

        if params[:scan_context_id].present?
          scan_context = scan_contexts.find { |c| c.id == params[:scan_context_id] }
          unless scan_context
            return render json: { error: "Invalid scan context" }, status: :unprocessable_entity
          end
        elsif scan_contexts.size == 1
          scan_context = scan_contexts.first
        else
          return render json: { error: "scan_context_id is required when multiple contexts exist" }, status: :unprocessable_entity
        end

        # Determine scan source and find participant_event
        scan_source = "qr"
        participant_event = nil

        # First, try NFC badge token lookup if provided
        if params[:badge_token].present?
          participant_event = NfcTokenResolver.call(event: @event, token: params[:badge_token])
          scan_source = "nfc" if participant_event
        end

        # Fall back to participant_id lookup (QR code flow)
        if participant_event.nil? && params[:participant_id].present?
          # Support both participant_event_id (from QR code) and participant_id
          participant_event = @event.participant_events
            .includes(:participant, :medical, :dietary, :safeguarding_info)
            .find_by(id: params[:participant_id])

          # Fall back to lookup by participant.id if not found by participant_event.id
          participant_event ||= @event.participant_events
            .joins(:participant)
            .includes(:participant, :medical, :dietary, :safeguarding_info)
            .find_by(participants: { id: params[:participant_id] })
        end

        # Manual search-based scan
        scan_source = "manual" if params[:source] == "manual"

        unless participant_event
          return render json: { error: "Participant not found for this event" }, status: :not_found
        end

        first_scan_in_context = participant_event.scans.where(scan_context: scan_context).none?

        scan = participant_event.scans.create!(
          user: current_user,
          scan_context: scan_context,
          scanned_at: params[:scanned_at] || Time.current,
          client_scan_id: params[:client_scan_id],
          source: scan_source
        )

        # Mark airport pickup for airport or check-in contexts on first scan in that context
        if (scan_context.is_airport? || scan_context.checks_in?) && first_scan_in_context
          mark_airport_pickup(participant_event, current_user)
        end

        # Prepare a user-owned token on first check-in when this event issues NFC hardware.
        if @event.nfc_badges_enabled? && scan_context.checks_in? && first_scan_in_context
          NfcToken.ensure_pending_for!(participant_event.participant.user) if participant_event.nfc_pairing_available?
        end

        render json: {
          success: true,
          first_scan_in_context: first_scan_in_context,
          scan: scan_json(scan),
          participant: participant_detail_json(participant_event)
        }
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def set_event
        @event = Event.find(params[:event_id])
      end

      def require_event_access
        require_event_access!(@event)
      end

      def scan_json(scan)
        {
          id: scan.id,
          participant_id: scan.participant.id,
          participant_event_id: scan.participant_event_id,
          scanned_at: scan.scanned_at.iso8601,
          scanned_by: scan.user.name,
          client_scan_id: scan.client_scan_id,
          source: scan.source,
          scan_context: scan.scan_context ? {
            id: scan.scan_context_id,
            name: scan.scan_context.name,
            checks_in: scan.scan_context.checks_in,
            is_airport: scan.scan_context.is_airport
          } : nil,
          created_at: scan.created_at.iso8601
        }
      end

      def participant_detail_json(pe)
        participant = pe.participant
        medical = pe.medical
        dietary = pe.dietary
        safeguarding = pe.safeguarding_info

        {
          participant_id: participant.id,
          participant_event_id: pe.id,
          display_name: participant.display_name,
          full_name: participant.full_name,
          email: participant.email,
          slack_user_id: participant.slack_user_id,
          phone: participant.phone,
          pronouns: participant.pronouns,
          tshirt_size: participant.tshirt_size,
          status: pe.status,

          has_anaphylaxis_risk: medical&.has_anaphylaxis_risk || false,
          requires_refrigeration: medical&.requires_refrigeration || false,
          allergies: medical&.allergies,
          medical_conditions: medical&.medical_conditions,
          medications: medical&.medications,

          diet_type: dietary&.diet_type,
          life_threatening_allergies: dietary&.life_threatening_allergies,
          cross_contamination_risk: dietary&.cross_contamination_risk || false,

          freedom_waiver_granted: safeguarding&.freedom_waiver_granted || false,
          high_support_flag: safeguarding&.high_support_flag || false,
          can_leave_unaccompanied: safeguarding&.can_leave_unaccompanied || false,

          waiver_signed: pe.waiver_signed?,

          nfc_badge_token: pe.event.nfc_badges_enabled? ? pe.pending_nfc_token&.token : nil,
          nfc_badge_assigned: pe.nfc_badge_assigned?,
          nfc_pairing_available: pe.nfc_pairing_available?,

          groups: pe.event.groups_enabled? ? pe.groups.ordered.map { |g| { id: g.id, name: g.name, color: g.normalized_color } } : []
        }
      end
    end
  end
end
