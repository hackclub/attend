module Admin
  # Guided setup wizard for newly created events. Step 1 (basics) lives on
  # EventsController#new/#create; the remaining steps here update the event
  # in place so organizers can leave and resume at any point.
  class EventSetupController < BaseController
    before_action :set_event

    STEPS = %w[basics schedule modules waivers team review].freeze

    before_action :require_staff_management_access, only: [ :add_team_member, :remove_team_member ]

    def show
      redirect_to resume_step_path
    end

    def schedule
    end

    def update_schedule
      if @event.update(schedule_params)
        redirect_to admin_event_setup_modules_path(@event)
      else
        render :schedule, status: :unprocessable_entity
      end
    end

    def modules
    end

    def update_modules
      if @event.update(module_params)
        redirect_to admin_event_setup_waivers_path(@event, return_to: params[:return_to].presence)
      else
        render :modules, status: :unprocessable_entity
      end
    end

    def waivers
    end

    def update_waivers
      case params[:waiver_mode]
      when "auto"
        setup_default_waivers
      when "manual"
        if @event.update(manual_waiver_params)
          redirect_to after_waivers_path, notice: "Waiver template IDs saved. Configure field mappings before opening registration."
        else
          render :waivers, status: :unprocessable_entity
        end
      else
        redirect_to after_waivers_path
      end
    end

    def team
      @event_role_assignments = @event.event_role_assignments.includes(:user).order("users.email")
      @event_role_assignment = @event.event_role_assignments.build
    end

    def add_team_member
      user = User.find_by(email: params[:email].to_s.strip.downcase)

      unless user
        redirect_to admin_event_setup_team_path(@event), alert: "User not found with that email. They need to sign in to Attend first."
        return
      end

      @event_role_assignment = @event.event_role_assignments.build(
        user: user,
        role: params.dig(:event_role_assignment, :role)
      )

      if @event_role_assignment.save
        notify_new_staff_member(@event_role_assignment)
        redirect_to admin_event_setup_team_path(@event), notice: "#{user.email} added as #{@event_role_assignment.role.humanize.downcase}."
      else
        redirect_to admin_event_setup_team_path(@event), alert: @event_role_assignment.errors.full_messages.to_sentence
      end
    end

    def remove_team_member
      @event_role_assignment = @event.event_role_assignments.find(params[:assignment_id])

      if @event_role_assignment.inherited_from_series?
        redirect_to admin_event_setup_team_path(@event),
          alert: "#{@event_role_assignment.user.email} is a series #{@event_role_assignment.series_role} — their access is inherited from the series, so they can't be removed here."
        return
      end

      @event_role_assignment.destroy
      redirect_to admin_event_setup_team_path(@event), notice: "Staff member removed."
    end

    def review
      @event_role_assignments = @event.event_role_assignments.includes(:user).order("users.email")
    end

    def complete
      if @event.support_email.blank?
        redirect_to edit_admin_event_path(@event),
          alert: "Set a support email (@hackclub.com or @events.hackclub.com) before finishing setup — it's the from and reply-to address on every participant and guardian email."
        return
      end

      @event.update!(setup_completed_at: Time.current) unless @event.setup_complete?
      redirect_to admin_event_dashboard_path(@event), notice: "#{@event.name} is ready to go!"
    end

    private

    def set_event
      @event = Event.find_by!(slug: params[:slug])
      authorize @event, :update?
      set_current_event(@event)
    end

    def resume_step_path
      if @event.starts_at.blank?
        admin_event_setup_schedule_path(@event)
      elsif @event.docuseal_waiver_template_id.blank? && !@event.setup_complete?
        admin_event_setup_waivers_path(@event)
      else
        admin_event_setup_review_path(@event)
      end
    end

    def setup_default_waivers
      results = { "waiver" => Docuseal::DefaultTemplateSetup.new(@event).call("waiver") }
      if @event.freedom_waivers_enabled?
        results["freedom_waiver"] = Docuseal::DefaultTemplateSetup.new(@event).call("freedom_waiver")
      end

      failures = results.reject { |_, result| result.success? }
      if failures.empty?
        redirect_to after_waivers_path, notice: "Waiver templates created and field mappings configured automatically."
      else
        successes = results.select { |_, result| result.success? }.keys.map(&:humanize)
        flash.now[:alert] = [
          successes.any? ? "Created: #{successes.join(', ')}." : nil,
          failures.map { |type, result| "#{type.humanize}: #{result.message}" }.join(" ")
        ].compact.join(" ")
        render :waivers, status: :unprocessable_entity
      end
    end

    def after_waivers_path
      if params[:return_to] == "integrations" || @event.setup_complete?
        admin_event_integrations_path(@event)
      else
        admin_event_setup_team_path(@event)
      end
    end

    # Mirrors EventStaffController#require_event_admin_access — only event
    # admins (or global admins) may change who has access to the event.
    def require_staff_management_access
      return if current_user.global_admin?
      return if current_user.event_admin_for?(@event)

      redirect_to admin_event_setup_team_path(@event), alert: "Only event admins can manage staff."
    end

    def schedule_params
      params.require(:event).permit(
        :starts_at, :ends_at,
        :registration_open_at, :registration_close_at,
        :location_city, :location_country, :location_address,
        :location_latitude, :location_longitude,
        :venue_name
      )
    end

    def module_params
      params.require(:event).permit(
        :freedom_waivers_enabled,
        :travel_enabled,
        :visa_options_enabled,
        :visa_application_url,
        :accommodation_enabled,
        :roommate_preferences_enabled,
        :guardian_invites_locked,
        :nfc_badges_enabled,
        :nfc_badge_write_on_checkin_enabled,
        :groups_enabled
      )
    end

    def manual_waiver_params
      params.require(:event).permit(
        :docuseal_waiver_template_id,
        :docuseal_freedom_waiver_template_id
      )
    end
  end
end
