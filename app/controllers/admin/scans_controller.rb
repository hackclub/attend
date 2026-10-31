module Admin
  class ScansController < BaseController
    include TravelPickupMarkable
    before_action :require_event_selected
    before_action :set_scan, only: [ :update ]
    before_action :require_global_admin, only: [ :update ]

    def index
      @scan_contexts = current_event.scan_contexts.to_a
      all_scans = Scan.for_event(current_event)
      today_scans = all_scans.where(scanned_at: event_today)

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
      # A stay's arrival point is measured against the people with a room in
      # that stay, so it reaches 100% when everyone expected has arrived.
      stays = current_event.rooming_contexts.where(scan_context_id: context_ids).index_by(&:scan_context_id)
      @per_context_stats = @scan_contexts.map do |ctx|
        stay = stays[ctx.id]
        {
          context: ctx, today: today_by_context[ctx.id] || 0, total: total_by_context[ctx.id] || 0,
          stay: stay, expected: stay&.expected_count, arrived: stay&.arrived_count
        }
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
        .where(scanned_at: event_today)
        .includes(:user, :scan_context, :participant, participant_event: :participant)
        .recent
        .limit(50)

      @scan_contexts = current_event.scan_contexts.to_a
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
        participant_event = NfcTokenResolver.call(event: current_event, token: params[:badge_token])
        scan_source = "nfc" if participant_event
      end

      # Fall back to participant identifier lookup (QR code flow)
      if participant_event.nil? && params[:participant_id].present?
        participant_event = ScanParticipantResolver.call(
          event: current_event,
          identifier: params[:participant_id],
          includes: [ :participant, :medical, :dietary ]
        )
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

      if scan_context.is_travel_pickup? && first_scan_in_context
        mark_travel_pickup(participant_event, current_user)
      end

      if scan_context.is_travel_pickup? || scan_context.checks_in?
        TravelCalendar::JourneyCache.clear(current_event)
      end

      # Auto-generate NFC badge token on first check-in if NFC is enabled
      if current_event.nfc_badges_enabled? && scan_context.checks_in? && first_scan_in_context
        participant_event.ensure_nfc_badge_token!
      end

      participant = participant_event.participant
      # At a stay's arrival point, the desk needs the room, and to know when
      # someone has no room in that stay at all.
      stay = scan_context.rooming_context
      stay_room = stay && participant_event.room_assignments.find_by(rooming_context: stay)&.room
      # Flags only: the allergy free text stays on the medical page.
      food_safety = participant_event.food_safety_summary

      render json: {
        success: true,
        scan_id: scan.id,
        first_scan_in_context: first_scan_in_context,
        scanned_by: current_user.display_name_or_fallback,
        scanned_at: scan.scanned_at.iso8601,
        scan_context: {
          id: scan_context.id,
          name: scan_context.name,
          checks_in: scan_context.checks_in,
          is_travel_pickup: scan_context.is_travel_pickup
        },
        stay: stay && { name: stay.name, room: stay_room&.display_name },
        participant: {
          id: participant.id,
          participant_event_id: participant_event.id,
          display_name: participant.display_name,
          full_name: participant.full_name,
          email: participant.email,
          # The phone is omitted, not blanked, for PII-restricted roles; the
          # scanner modal hides that row entirely for them.
          **(can_view_participant_pii? ? { phone: participant.phone } : {}),
          pronouns: participant.pronouns,
          tshirt_size: participant.tshirt_size,
          status: participant_event.status,
          display_status: participant_event.display_status,
          has_anaphylaxis_risk: food_safety.anaphylaxis_risk?,
          requires_refrigeration: participant_event.medical&.requires_refrigeration || false,
          dietary: food_safety.diet_type,
          # Health-form allergies are a medical fact, so only roles that can
          # open the medical summary learn whether there are any.
          **(policy(participant_event.medical || Medical.new(participant_event: participant_event)).show? ? { has_allergies: food_safety.allergies? } : {}),
          has_life_threatening_food_allergies: food_safety.life_threatening_food_allergies?,
          cross_contamination_risk: food_safety.cross_contamination_risk?,
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

      # The participant profile links here for one person's scans. It filters by
      # id rather than putting their email in the URL, which roles that can't
      # see contact details must not be handed.
      if params[:participant_event_id].present?
        @scans = @scans.where(participant_event_id: params[:participant_event_id])
      end

      if params[:scan_context_id].present?
        @scans = @scans.where(scan_context_id: params[:scan_context_id])
      end

      if params[:user_id].present?
        @scans = @scans.where(user_id: params[:user_id])
      end

      # A calendar day on the event's clock, as event_today is.
      if params[:date].present?
        date = Date.parse(params[:date]) rescue nil
        if date
          @scans = @scans.where(scanned_at: date.in_time_zone(current_event.event_time_zone).all_day)
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

    # Scan times are instants, so "today" is the event's calendar day rather
    # than the UTC one, which ends in the afternoon or evening at a US event.
    def event_today
      Time.current.in_time_zone(current_event.event_time_zone).all_day
    end

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
