module Admin
  # Who's staying for an eligible-only stay, and why. Organizers add people by
  # picking registrations, pasting emails (or a whole CSV), or adding a group;
  # a shop can add them through the API. Taking someone off also frees any
  # room they had in this stay.
  class RoomingRosterEntriesController < BaseController
    before_action :set_event
    before_action :require_event_selected
    before_action :authorize_rooming!
    before_action :set_stay

    def index
      load_roster
    end

    def create
      roster = Rooming::Roster.new(@stay, added_by: current_user)
      option = @stay.eligibility_options.find_by(id: params[:eligibility_option_id])

      @result = case params[:mode]
      when "emails"
        roster.add_emails(params[:emails], option: option)
      when "group"
        group = @event.groups.find(params[:group_id])
        roster.add_participant_events(group.participant_events.where(event: @event), source: :group, option: option)
      else
        ids = Array(params[:participant_event_ids]).reject(&:blank?)
        roster.add_participant_events(@event.participant_events.where(id: ids), source: :manual, option: option)
      end
      @record = @result.added.last || @result.updated.last

      # Unmatched emails can be a long list, too long for the flash cookie, so
      # the paste form posts without Turbo and its result renders in place.
      if @result.not_registered.present?
        load_roster
        render :index
      else
        redirect_to admin_event_rooming_stay_roster_entries_path(@event.slug, @stay), notice: summary(@result)
      end
    end

    def destroy
      @record = @stay.roster_entries.find(params[:id])
      @record.destroy!

      redirect_to admin_event_rooming_stay_roster_entries_path(@event.slug, @stay), notice: "Removed from #{@stay.name}."
    end

    private

    def set_event
      @event = Event.find_by!(slug: params[:event_slug])
    end

    def authorize_rooming!
      authorize @event, :manage_rooming?
    end

    def set_stay
      @stay = @event.rooming_contexts.find(params[:rooming_stay_id])
      return if @stay.eligible_only?

      redirect_to admin_event_rooming_stays_path(@event.slug),
        alert: "#{@stay.name} includes everyone with accommodation, so it has no list. Edit it and choose \"Only people on its list\" to pick who's in it."
    end

    def load_roster
      @entries = @stay.roster_entries
        .includes(:eligibility_option, :added_by_user, participant_event: :participant)
        .sort_by { |entry| entry.participant_event.participant.full_name.to_s.downcase }
      @in_pool_ids = @stay.participant_events.pluck(:id).to_set
      @available = @event.participant_events
        .where.not(status: %w[withdrawn rejected])
        .where.not(id: @stay.roster_entries.select(:participant_event_id))
        .includes(:participant)
        .sort_by { |participant_event| participant_event.participant.full_name.to_s.downcase }
      @groups = @event.groups_enabled? ? @event.groups.ordered : Group.none
    end

    def summary(result)
      parts = []
      parts << "#{result.added.size} added" if result.added.any?
      parts << "#{result.updated.size} already on the list" if result.updated.any?
      parts.any? ? "#{parts.join(', ').upcase_first}." : "Nobody to add."
    end
  end
end
