module Admin
  class EventsController < BaseController
    skip_before_action :set_current_event_from_session, only: [ :select ]

    def new
      @event = Event.new
      @event.event_series = EventSeries.find_by(slug: params[:series]) if params[:series].present?
      authorize @event
    end

    def create
      @event = Event.new(event_params)
      authorize @event

      if @event.save
        ensure_creator_has_admin_role
        redirect_to admin_event_setup_schedule_path(@event), notice: "#{@event.name} created! Let's finish setting it up."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @event = Event.find_by!(slug: params[:slug])
      authorize @event
    end

    def update
      @event = Event.find_by!(slug: params[:slug])
      authorize @event

      if @event.update(event_params)
        redirect_to admin_event_dashboard_path(@event), notice: "Event was successfully updated."
      else
        render :edit, status: :unprocessable_entity
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
      redirect_to admin_event_integrations_path(@event), notice: "API key generated successfully."
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
        :location_city,
        :location_country,
        :location_address,
        :location_latitude,
        :location_longitude,
        :venue_name,
        :timezone,
        :support_email,
        :freedom_waivers_enabled,
        :travel_enabled,
        :visa_options_enabled,
        :visa_application_url,
        :accommodation_enabled,
        :roommate_preferences_enabled,
        :guardian_invites_locked,
        :hotel_scan_context_id,
        :nfc_badges_enabled,
        :nfc_badge_write_on_checkin_enabled,
        :groups_enabled
      )
      unless action_name == "create" || current_user.global_admin?
        permitted = permitted.except(:event_series_id)
      end
      permitted
    end
  end
end
