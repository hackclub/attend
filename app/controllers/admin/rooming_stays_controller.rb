module Admin
  # The stays at an event: during the event, before, after, other. Each is
  # either everyone with accommodation (minus anyone marked exempt) or only
  # the people on its list, and gets its own run through the rooming wizard.
  # Any of them can go, including during the event: an event where everyone
  # sleeps at the venue may not need one.
  class RoomingStaysController < BaseController
    before_action :set_event
    before_action :require_event_selected
    before_action :authorize_rooming!
    before_action :set_stay, only: %i[edit update destroy]

    BLANK_OPTION_ROWS = 2

    def index
      load_stays
      @new_stay = self.class.new_stay_for(@event)
    end

    def create
      @record = @new_stay = @event.rooming_contexts.new(stay_params)

      if @new_stay.save
        redirect_to after_save_path, notice: "#{@new_stay.name} added."
      else
        load_stays
        pad_option_rows(@new_stay)
        render :index, status: :unprocessable_entity
      end
    end

    def edit
      pad_option_rows(@stay)
    end

    def update
      @record = @stay

      if @stay.update(stay_params)
        redirect_to after_save_path, notice: "#{@stay.name} saved."
      else
        pad_option_rows(@stay)
        render :edit, status: :unprocessable_entity
      end
    end

    # Removing a stay takes its rooms, room assignments and list with it.
    def destroy
      @record = @stay
      @stay.destroy!
      redirect_to after_save_path, notice: "#{@stay.name} removed."
    end

    private

    def set_event
      @event = Event.find_by!(slug: params[:event_slug])
    end

    def authorize_rooming!
      authorize @event, :manage_rooming?
    end

    def set_stay
      @stay = @event.rooming_contexts.find(params[:id])
    end

    def stay_params
      params.require(:rooming_context).permit(:name, :kind, :enrollment, :starts_on, :ends_on,
        eligibility_options_attributes: %i[id label price position _destroy])
    end

    # Shared with the event setup wizard's step, which shows the same list.
    def load_stays
      @stays, @roster_counts, @exempt_count = self.class.stays_overview(@event)
    end

    def self.stays_overview(event)
      stays = event.rooming_contexts.ordered.includes(:eligibility_options, :rooms).to_a
      roster_counts = RoomingRosterEntry.where(rooming_context: stays).group(:rooming_context_id).count
      exempt_count = event.participant_events.where(status: %w[complete in_progress])
        .joins(:accommodation).where(accommodations: { rooming_exempt: true }).count
      [ stays, roster_counts, exempt_count ]
    end

    # Most events start with the stay during the event, so that's the first
    # one offered; after that, the night before or after.
    def self.new_stay_for(event)
      stay = if event.rooming_contexts.main.exists?
        event.rooming_contexts.new(kind: :post_event, enrollment: :eligible_only)
      else
        event.rooming_contexts.new(kind: :main, enrollment: :everyone, name: RoomingContext::MAIN_NAME)
      end
      BLANK_OPTION_ROWS.times { stay.eligibility_options.build }
      stay
    end

    def pad_option_rows(stay)
      BLANK_OPTION_ROWS.times { stay.eligibility_options.build }
    end

    # The event setup wizard adds stays from its own step and wants to land
    # back there.
    def after_save_path
      if params[:return_to] == "setup"
        admin_event_setup_stays_path(@event)
      else
        admin_event_rooming_stays_path(@event.slug)
      end
    end
  end
end
