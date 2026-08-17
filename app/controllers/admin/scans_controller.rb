module Admin
  class ScansController < BaseController
    include AirportPickupMarkable
    before_action :require_event_selected
    before_action :set_scan, only: [ :update ]
    before_action :require_global_admin, only: [ :update ]

    def index
      @scan_contexts = current_event.scan_contexts.to_a
      all_scans = Scan.for_event(current_event)
      today_scans = all_scans.today

      @scans_today = today_scans.count
      @scans_total = all_scans.count
      @checked_in_today = today_scans
        .joins(:scan_context)
        .where(scan_contexts: { checks_in: true })
        .distinct.count(:participant_event_id)
      @checked_in_total = current_event.participant_events
        .joins(scans: :scan_context)
        .where(scan_contexts: { checks_in: true })
        .distinct.count

      context_ids = @scan_contexts.map(&:id)
      today_by_context = today_scans.where(scan_context_id: context_ids).group(:scan_context_id).count
      total_by_context = all_scans.where(scan_context_id: context_ids).group(:scan_context_id).count
      @per_context_stats = @scan_contexts.map do |ctx|
        { context: ctx, today: today_by_context[ctx.id] || 0, total: total_by_context[ctx.id] || 0 }
      end

      @recent_scans = all_scans
        .includes(:user, :scan_context, :participant, participant_event: :participant)
        .recent
        .limit(10)

      @top_staff_today = today_scans
        .joins(:user)
        .group("users.id", "users.name", "users.email")
        .order(Arel.sql("COUNT(*) DESC"))
        .limit(5)
        .count
    end

    def scanner
      @recent_scans = Scan.for_event(current_event)
        .today
        .includes(:user, :scan_context, :participant, participant_event: :participant)
        .recent
        .limit(50)

      @scan_contexts = current_event.scan_contexts
      @default_scan_context = @scan_contexts.find { |c| c.checks_in? } || @scan_contexts.first
    end

    def search
      query = params[:q].to_s.strip
      return render json: { results: [] } if query.blank?

      participant_events = current_event.participant_events
        .joins(:participant)
        .includes(:participant)
        .where(
          "LOWER(participants.legal_first_name) LIKE :q OR " \
          "LOWER(participants.legal_last_name) LIKE :q OR " \
          "LOWER(participants.preferred_name) LIKE :q OR " \
          "LOWER(CAST(participants.id AS TEXT)) LIKE :q",
          q: "#{query.downcase}%"
        )
        .limit(10)

      groups_enabled = current_event.groups_enabled?
      participant_events = participant_events.includes(:groups) if groups_enabled

      results = participant_events.map do |pe|
        participant = pe.participant
        name_parts = [ participant.legal_first_name ]
        if participant.preferred_name.present? && participant.preferred_name.casecmp(participant.legal_first_name) != 0
          name_parts << "(#{participant.preferred_name})"
        end
        name_parts << participant.legal_last_name
        {
          id: participant.id,
          display_name: name_parts.compact_blank.join(" "),
          short_id: participant.id[0..7].upcase,
          status: pe.status,
          show_url: admin_event_participant_path(current_event, pe),
          groups: groups_enabled ? pe.groups.map { |g| { id: g.id, name: g.name, color: g.normalized_color } } : []
        }
      end

      render json: { results: results }
    end

    def create
      scan_contexts = current_event.scan_contexts.to_a

      if scan_contexts.empty?
        render json: { error: "No scan context configured for this event" }, status: :unprocessable_entity
        return
      end

      if params[:scan_context_id].present?
        scan_context = scan_contexts.find { |c| c.id == params[:scan_context_id] }
        unless scan_context
          render json: { error: "Invalid scan context" }, status: :unprocessable_entity
          return
        end
      elsif scan_contexts.size == 1
        scan_context = scan_contexts.first
      else
        render json: { error: "scan_context_id is required when multiple contexts exist" }, status: :unprocessable_entity
        return
      end

      # Determine scan source and find participant_event
      scan_source = "qr"
      participant_event = nil

      # First, try NFC badge token lookup if provided
      if params[:badge_token].present?
        participant_event = current_event.participant_events
          .includes(:participant, :medical, :dietary)
          .find_by(nfc_badge_token: params[:badge_token])
        scan_source = "nfc" if participant_event
      end

      # Fall back to participant_id lookup (QR code flow)
      if participant_event.nil? && params[:participant_id].present?
        participant_event = current_event.participant_events
          .joins(:participant)
          .includes(:medical, :dietary)
          .find_by(participants: { id: params[:participant_id] })
      end

      unless participant_event
        render json: { error: "Participant not found for this event" }, status: :not_found
        return
      end

      first_scan_in_context = participant_event.scans.where(scan_context: scan_context).none?

      scan = participant_event.scans.create!(
        user: current_user,
        scan_context: scan_context,
        scanned_at: Time.current,
        source: scan_source
      )

      # Mark airport pickup for airport or check-in contexts on first scan in that context
      if (scan_context.is_airport? || scan_context.checks_in?) && first_scan_in_context
        mark_airport_pickup(participant_event, current_user)
      end

      # Auto-generate NFC badge token on first check-in if NFC is enabled
      if current_event.nfc_badges_enabled? && scan_context.checks_in? && first_scan_in_context
        participant_event.ensure_nfc_badge_token!
      end

      participant = participant_event.participant

      render json: {
        success: true,
        scan_id: scan.id,
        first_scan_in_context: first_scan_in_context,
        scanned_by: current_user.display_name_or_fallback,
        scan_context: {
          id: scan_context.id,
          name: scan_context.name,
          checks_in: scan_context.checks_in,
          is_airport: scan_context.is_airport
        },
        participant: {
          id: participant.id,
          participant_event_id: participant_event.id,
          display_name: participant.display_name,
          full_name: participant.full_name,
          email: participant.email,
          phone: participant.phone,
          pronouns: participant.pronouns,
          tshirt_size: participant.tshirt_size,
          status: participant_event.status,
          has_anaphylaxis_risk: participant_event.medical&.has_anaphylaxis_risk || false,
          requires_refrigeration: participant_event.medical&.requires_refrigeration || false,
          dietary: participant_event.dietary&.diet_type,
          show_url: admin_event_participant_path(current_event, participant_event),
          nfc_badge_token: current_event.nfc_badges_enabled? ? participant_event.nfc_badge_token : nil,
          nfc_badge_assigned: participant_event.nfc_badge_assigned?,
          slack_user_id: participant.slack_user_id,
          groups: current_event.groups_enabled? ? participant_event.groups.ordered.map { |g| { id: g.id, name: g.name, color: g.normalized_color } } : []
        }
      }
    end

    def history
      @scans = Scan.for_event(current_event)
        .includes(:user, :scan_context, :participant, participant_event: :participant)
        .recent

      if params[:search].present?
        search_term = "%#{params[:search].downcase}%"
        @scans = @scans.joins(participant_event: :participant)
          .where(
            "LOWER(participants.legal_first_name) LIKE :q OR " \
            "LOWER(participants.legal_last_name) LIKE :q OR " \
            "LOWER(participants.preferred_name) LIKE :q OR " \
            "LOWER(participants.email) LIKE :q",
            q: search_term
          )
      end

      if params[:scan_context_id].present?
        @scans = @scans.where(scan_context_id: params[:scan_context_id])
      end

      if params[:user_id].present?
        @scans = @scans.where(user_id: params[:user_id])
      end

      if params[:date].present?
        date = Date.parse(params[:date]) rescue nil
        if date
          @scans = @scans.where(scanned_at: date.beginning_of_day..date.end_of_day)
        end
      end

      if current_event.groups_enabled? && params[:group_id].present?
        if params[:group_id] == "none"
          @scans = @scans.where.not(participant_event_id: GroupMembership.select(:participant_event_id))
        else
          @scans = @scans.where(participant_event_id: GroupMembership.where(group_id: params[:group_id]).select(:participant_event_id))
        end
      end

      @page = (params[:page] || 1).to_i
      @per_page = 50
      @total_count = @scans.count
      @scans = @scans.offset((@page - 1) * @per_page).limit(@per_page)
      @scan_contexts = current_event.scan_contexts
      @staff_users = User.joins(:event_role_assignments)
        .where(event_role_assignments: { event_id: current_event.id })
        .or(User.where(global_role: "global_admin"))
        .distinct
        .order(:name)
    end

    def update
      if @scan.update(scan_params)
        redirect_to history_admin_event_scans_path(current_event), notice: "Scan updated successfully."
      else
        redirect_to history_admin_event_scans_path(current_event), alert: "Failed to update scan: #{@scan.errors.full_messages.join(', ')}"
      end
    end

    private

    def set_scan
      @scan = Scan.for_event(current_event).find(params[:id])
    end

    def require_global_admin
      unless current_user.global_admin?
        redirect_to history_admin_event_scans_path(current_event), alert: "Only global admins can edit scans."
      end
    end

    def scan_params
      params.require(:scan).permit(:scan_context_id, :user_id)
    end
  end
end
