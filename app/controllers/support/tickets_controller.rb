module Support
  class TicketsController < Admin::BaseController
    before_action :skip_require_event
    before_action :set_ticket, only: %i[show close reopen assign set_event set_subject]
    after_action :verify_authorized
    # Each ticket in a batch is audited individually in #bulk_close, so the
    # blanket one-record-per-request hook has nothing useful to record here.
    skip_after_action :log_admin_action, only: :bulk_close

    helper_method :can_link_ticket_to_event?, :ticket_filter_params

    UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    def index
      authorize Ticket
      @tickets = filtered_tickets.includes(:event, :assigned_to)
      @assignees = assignee_options
      @filtering = ticket_filter_params.any?
    end

    def show
      authorize @ticket
      @message = TicketMessage.new
      @note = Note.new

      @matching_participants = @ticket.matching_participants
      @matching_guardians = @ticket.matching_guardians
      @linked_participants = @ticket.event ? @ticket.linked_participants_for_event : @ticket.all_linked_participants

      unless current_user.global_admin?
        staffed = current_user.support_staff_event_ids
        @matching_participants = @matching_participants.select { |p| p.events.any? { |e| staffed.include?(e.id) } }
        @matching_guardians = @matching_guardians.select { |g| g.participant_events.any? { |pe| staffed.include?(pe.event_id) } }
      end

      @previous_tickets = policy_scope(Ticket)
                            .where(phone_number: @ticket.phone_number)
                            .where.not(id: @ticket.id)
                            .recent_first
                            .limit(10)
    end

    def bulk_close
      authorize Ticket, :bulk_close?

      ids = Array(params[:ticket_ids]).select { |id| id.to_s.match?(UUID_FORMAT) }
      closed = 0

      policy_scope(Ticket).where(id: ids, status: :open).find_each do |ticket|
        next unless TicketPolicy.new(current_user, ticket).update?

        ticket.close!(user: current_user)
        log_bulk_close(ticket)
        closed += 1
      end

      notice = if closed.zero?
        "No tickets were closed."
      else
        "Closed #{closed} #{'ticket'.pluralize(closed)}."
      end

      redirect_to support_tickets_path(ticket_filter_params), notice: notice, status: :see_other
    end

    def close
      authorize @ticket, :update?
      @ticket.close!(user: current_user)

      respond_to do |format|
        format.turbo_stream { redirect_to support_tickets_path, notice: "Ticket closed." }
        format.html { redirect_to support_tickets_path, notice: "Ticket closed." }
      end
    end

    def reopen
      authorize @ticket, :update?
      @ticket.reopen!

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to support_ticket_path(@ticket), notice: "Ticket reopened." }
      end
    end

    def assign
      authorize @ticket, :update?
      @ticket.update!(assigned_to_id: params[:user_id].presence)

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to support_ticket_path(@ticket), notice: "Ticket assigned." }
      end
    end

    def set_event
      authorize @ticket, :update?
      return reject_unstaffed_event unless can_link_ticket_to_event_id?(params[:event_id].presence)

      @ticket.update!(event_id: params[:event_id].presence)

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to support_ticket_path(@ticket), notice: "Event updated." }
      end
    end

    def set_subject
      authorize @ticket, :update?
      return reject_unstaffed_event unless can_link_ticket_to_event_id?(params[:event_id].presence)

      if params[:subject_type].present? && params[:subject_id].present?
        updates = { subject_type: params[:subject_type], subject_id: params[:subject_id] }
        updates[:event_id] = params[:event_id] if params[:event_id].present?
        @ticket.update!(updates)
      else
        @ticket.update!(subject_type: nil, subject_id: nil)
      end

      redirect_to support_ticket_path(@ticket), notice: "Contact linked."
    end

    private

    # Filters the inbox by contact name, phone number, channel, assignee and
    # status. Each one is skipped when its param is blank.
    def filtered_tickets
      scope = policy_scope(Ticket).recent_first
      scope = scope.where(status: params[:status]) if Ticket.statuses.key?(params[:status])
      scope = scope.where(channel: params[:channel]) if Ticket.channels.key?(params[:channel])
      scope = filter_by_assignee(scope)
      scope = filter_by_phone(scope)
      filter_by_name(scope)
    end

    def filter_by_assignee(scope)
      assignee = params[:assignee].to_s
      return scope if assignee.blank?
      return scope.where(assigned_to_id: nil) if assignee == "unassigned"
      return scope.none unless assignee.match?(UUID_FORMAT)

      scope.where(assigned_to_id: assignee)
    end

    # Phone numbers are stored in E.164 but staff type them however they like,
    # so both sides are reduced to digits before matching.
    def filter_by_phone(scope)
      digits = params[:phone].to_s.gsub(/\D/, "")
      return scope if digits.blank?

      scope.where("regexp_replace(tickets.phone_number, '[^0-9]', '', 'g') LIKE ?", "%#{digits}%")
    end

    # Matches the linked contact shown in the Contact column, which is either a
    # Participant or a Guardian.
    def filter_by_name(scope)
      query = params[:q].to_s.strip
      return scope if query.blank?

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      participants = Participant.where(
        "legal_first_name ILIKE :name OR legal_last_name ILIKE :name OR preferred_name ILIKE :name " \
        "OR (legal_first_name || ' ' || legal_last_name) ILIKE :name",
        name: pattern
      ).select(:id)
      guardians = Guardian.where(
        "legal_first_name ILIKE :name OR legal_last_name ILIKE :name " \
        "OR (legal_first_name || ' ' || legal_last_name) ILIKE :name",
        name: pattern
      ).select(:id)

      scope.where(subject_type: "Participant", subject_id: participants)
           .or(scope.where(subject_type: "Guardian", subject_id: guardians))
    end

    def assignee_options
      ids = policy_scope(Ticket).where.not(assigned_to_id: nil).distinct.pluck(:assigned_to_id)
      User.where(id: ids).sort_by { |user| user.display_name_or_fallback.to_s.downcase }
    end

    def ticket_filter_params
      @ticket_filter_params ||= params.permit(:q, :phone, :channel, :assignee, :status)
                                      .to_h
                                      .symbolize_keys
                                      .compact_blank
    end

    # Admin::BaseController's blanket audit hook can only record one record per
    # request, so each closed ticket is logged explicitly instead.
    def log_bulk_close(ticket)
      AuditLog.log!(
        action: "close",
        record: ticket,
        actor: current_user,
        event: ticket.event,
        changed_fields: ticket.previous_changes.except("updated_at", "created_at"),
        metadata: {
          ip: request.remote_ip,
          user_agent: request.user_agent,
          controller: controller_name,
          bulk: true
        }
      )
    rescue => e
      Rails.logger.error("[Support::Tickets] Failed to audit bulk close for #{ticket.id}: #{e.class} - #{e.message}")
    end

    def set_ticket
      @ticket = Ticket.find(params[:id])
    end

    def can_link_ticket_to_event?(event)
      current_user.global_admin? || current_user.support_staff_event_ids.include?(event.id)
    end

    def can_link_ticket_to_event_id?(event_id)
      event_id.blank? || current_user.global_admin? || current_user.support_staff_event_ids.include?(event_id)
    end

    def reject_unstaffed_event
      redirect_to support_ticket_path(@ticket), alert: "You can only link tickets to events you staff."
    end

    def skip_require_event
      # Support tickets are global, not event-specific
    end
  end
end
