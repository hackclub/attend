module Support
  class TicketsController < Admin::BaseController
    before_action :skip_require_event
    before_action :set_ticket, only: %i[show close reopen assign set_event set_subject merge]
    after_action :verify_authorized

    helper_method :can_link_ticket_to_event?

    def index
      authorize Ticket
      @tickets = policy_scope(Ticket).unmerged.recent_first.includes(:event, :assigned_to)
    end

    def show
      authorize @ticket
      return redirect_to_merge_root if @ticket.merged?

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
                            .unmerged
                            .where(phone_number: @ticket.phone_number)
                            .where.not(id: @ticket.id)
                            .recent_first
                            .limit(10)

      @merged_sources = @ticket.merged_tickets.includes(:merged_by).order(:merged_at)
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
      return redirect_to_merge_root if @ticket.merged?

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

    # Folds another ticket with the same phone number into this one, so a contact
    # coming back to a closed ticket reads as one conversation.
    def merge
      authorize @ticket, :merge?
      source = policy_scope(Ticket).find(params[:source_id])
      authorize source, :merge?

      result = ::Support::MergeTickets.call(source: source, target: @ticket, user: current_user)

      notice = "Merged ##{source.id[0..7]} into this ticket " \
               "(#{helpers.pluralize(result.moved_messages, 'message')})."
      notice += " Ticket reopened." if result.reopened

      redirect_to support_ticket_path(@ticket), notice: notice
    rescue ::Support::MergeTickets::MergeError => e
      redirect_to support_ticket_path(@ticket), alert: e.message
    end

    private

    def redirect_to_merge_root
      root = @ticket.merge_root
      redirect_to support_ticket_path(root),
                  notice: "Ticket ##{@ticket.id[0..7]} was merged into ##{root.id[0..7]}."
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
