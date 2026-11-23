module Admin
  class EventsController < BaseController
    global_page only: :new
    skip_before_action :set_current_event_from_session, only: [ :select ]

    def new
      @event = Event.new
      @event.event_series = EventSeries.find_by(slug: params[:series]) if params[:series].present?
      @creation_invite = creation_invite
      @event.event_series = @creation_invite.event_series if @creation_invite
      authorize_new_event
    end

    def create
      @event = Event.new(event_params)
      @creation_invite = creation_invite
      # The invite decides which series, if any, the event belongs to.
      @event.event_series_id = @creation_invite.event_series_id if @creation_invite
      authorize_new_event

      if save_new_event
        ensure_creator_has_admin_role
        # As the setup wizard it lands on does, so the audit row is the new
        # event's rather than whichever one was picked.
        set_current_event(@event)
        redirect_to admin_event_setup_schedule_path(@event), notice: "#{@event.name} created! Let's finish setting it up."
      elsif @creation_invite&.completed?
        # A second submit of the same form: the first one made the event.
        redirect_to admin_event_setup_path(@creation_invite.event)
      else
        render :new, status: :unprocessable_entity
      end
    end

    # The event's own settings page selects it, like every page under
    # /admin/events/:event_slug does (BaseController#switch_event_if_needed).
    # This route's param is :slug, so that doesn't happen on its own.
    def edit
      @event = Event.find_by!(slug: params[:slug])
      authorize @event
      set_current_event(@event) unless current_event&.id == @event.id
    end

    # The Features settings tab. The original admin has no tabs: its edit
    # form still carries every one of these fields.
    def features
      @event = Event.find_by!(slug: params[:slug])
      authorize @event, :update?
      set_current_event(@event) unless current_event&.id == @event.id

      unless helpers.console_ui?
        flash.keep
        redirect_to edit_admin_event_path(@event)
      end
    end

    # Where a save from the setup wizard's Basics step goes back to. It rides
    # on the form as a hidden field, so a later plain edit isn't affected and
    # a slug change on the same save still lands in setup.
    SETUP_RETURNS = %w[setup review].freeze

    def update
      @event = Event.find_by!(slug: params[:slug])
      authorize @event

      if @event.update(event_params)
        redirect_to after_update_path, notice: params[:return_to].in?(SETUP_RETURNS) ? "Basics saved." : "Event was successfully updated."
      else
        render(features_tab? ? :features : :edit, status: :unprocessable_entity)
      end
    end

    # Attaches a single image (logo or banner) immediately when it's selected,
    # so admins don't have to submit the whole (multipart) form and wait for the
    # upload on save. Called via fetch from the instant_upload Stimulus controller.
    def attach_image
      @event = Event.find_by!(slug: params[:slug])
      authorize @event, :update?

      field = params[:field].to_s
      unless %w[logo banner].include?(field)
        render json: { success: false, error: "Unknown image field." }, status: :unprocessable_entity
        return
      end

      if params[:file].blank?
        render json: { success: false, error: "No file provided." }, status: :unprocessable_entity
        return
      end

      @event.public_send(field).attach(params[:file])

      if @event.save
        render json: {
          success: true,
          preview_html: render_to_string(
            partial: "admin/events/image_preview",
            locals: { event: @event, field: field },
            formats: [ :html ]
          )
        }
      else
        render json: { success: false, error: @event.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end
    end

    def select
      @event = Event.find_by!(slug: params[:slug])
      authorize @event

      set_current_event(@event)
      redirect_to admin_event_dashboard_path(@event), notice: "Now managing #{@event.name}."
    end

    def regenerate_api_key
      @event = Event.find_by!(slug: params[:slug])
      authorize @event

      api_key = @event.generate_api_key!
      flash[:api_key] = api_key
      redirect_to admin_event_api_access_path(@event), notice: "API key generated successfully."
    end

    def clear_waiver_dates_warning
      @event = Event.find_by!(slug: params[:slug])
      authorize @event

      @event.clear_waiver_dates_stale!
      redirect_back fallback_location: admin_event_dashboard_path(@event), notice: "Waiver date warning cleared."
    end

    def destroy
      @event = Event.find_by!(slug: params[:slug])
      authorize @event

      unless params[:confirmation] == @event.name
        redirect_to edit_admin_event_path(@event), alert: "Event name did not match. Event was not deleted."
        return
      end

      event_name = @event.name
      @event.destroy!
      redirect_to admin_root_path, notice: "Event '#{event_name}' was permanently deleted."
    end

    private

    # Someone invited to create an event (EventCreationInvite) isn't an admin
    # of anything until it exists, so these two actions let them in on the
    # invite alone. EventPolicy#create? still decides.
    def authorize_admin_access
      return if action_name.in?(%w[new create]) && EventCreationInvite.usable_by(current_user).exists?

      super
    end

    # The invite this event is being created under, if any: the one the form
    # names, or, for someone with no right of their own to create @event, the
    # one they've accepted. Global admins never need one.
    def creation_invite
      return nil if current_user.global_admin?

      invites = EventCreationInvite.usable_by(current_user)
      return invites.find_by(id: params[:invite]) if params[:invite].present?
      return nil if policy(@event).create?

      invites.order(:accepted_at).first
    end

    # Either the person may create @event in their own right, or the create
    # is tied to a usable invite of theirs, which #save_new_event then uses
    # up. There is no third way: an invite never authorizes a create that
    # doesn't consume it.
    def authorize_new_event
      return authorize(@event, :create?) unless @creation_invite

      skip_authorization
    end

    # One invite makes one event: the invite is locked while the event saves
    # and marked used in the same transaction, so a double submit can't
    # create two.
    def save_new_event
      return @event.save unless @creation_invite

      @creation_invite.with_lock do
        next false unless @creation_invite.usable? && @event.save

        @creation_invite.complete!(@event)
        true
      end
    end

    # A create that failed re-renders the new event form, which isn't about
    # the picked event any more than #new is.
    def event_page?
      super && !(action_name == "create" && @event.new_record?)
    end

    def after_update_path
      case params[:return_to]
      when "setup" then admin_event_setup_schedule_path(@event)
      when "review" then admin_event_setup_review_path(@event)
      else
        case params[:tab]
        when "features" then features_admin_event_path(@event)
        when "general" then edit_admin_event_path(@event)
        # The original admin's single form sends no tab and goes back to the overview.
        else admin_event_dashboard_path(@event)
        end
      end
    end

    # Every box on a settings tab saves on its own, so a save goes back to the
    # tab it came from.
    def features_tab?
      params[:tab] == "features"
    end

    # Series members created this event themselves — give them an explicit
    # event_admin role so per-event tooling (setup wizard team step, staff
    # lists) reflects them without relying solely on the series fallback.
    def ensure_creator_has_admin_role
      return if current_user.global_admin?

      @event.event_role_assignments.find_or_create_by!(user: current_user, role: "event_admin")
    end

    def event_params
      # event_series_id is checked against series membership by
      # EventPolicy#create?; on update only global admins may move an event
      # between series.
      permitted = params.require(:event).permit(
        :event_series_id,
        :name,
        :slug,
        :logo,
        :banner,
        :starts_at,
        :ends_at,
        :registration_open_at,
        :registration_close_at,
        :arrival_opens_at,
        :arrival_closes_at,
        :location_city,
        :location_country,
        :location_address,
        :location_latitude,
        :location_longitude,
        :venue_name,
        :google_place_id,
        :timezone,
        :support_email,
        :invitation_letter_costs,
        :freedom_waivers_enabled,
        :travel_enabled,
        :visa_options_enabled,
        :visa_application_url,
        :visa_letters,
        :accommodation_enabled,
        :roommate_preferences_enabled,
        :guardian_invites_locked,
        :onboarding_invites_held,
        :nfc_badges_enabled,
        :nfc_badge_write_on_checkin_enabled,
        :groups_enabled,
        :github_linking,
        :itch_linking,
        :github_help_url,
        :itch_help_url
      )
      unless action_name == "create" || current_user.global_admin?
        permitted = permitted.except(:event_series_id)
      end
      # Who can apply for visa letters is an event admin's call, as on the
      # visa letter settings page. Whoever creates an event is one.
      unless action_name == "create" || policy(@event).review_visa_letters?
        permitted = permitted.except(:visa_letters)
      end
      permitted
    end
  end
end
