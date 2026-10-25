module Api
  module V1
    # Who has access to one event, and what they can do there — the API
    # equivalent of Admin::EventStaffController and the wizard's team step.
    #
    # Managing staff is the narrowest permission the web has: global admins and
    # this event's own admins, nobody else. API keys inherit that standing for
    # the events they're scoped to, so a series key can staff up every event in
    # its series and an event key can staff up its own.
    #
    # Roles come from EventRoleAssignment's enum; GET /events/:id/staff returns
    # the catalogue alongside the assignments so a client never has to hardcode
    # them.
    class EventStaffController < BaseController
      include Pundit::Authorization
      include Api::V1::EventScoped
      include Api::V1::ApiAuditing

      rescue_from Pundit::NotAuthorizedError do
        render json: { error: "Forbidden" }, status: :forbidden
      end

      before_action :set_assignment, only: [ :update, :destroy ]

      def index
        assignments = @event.event_role_assignments.includes(:user).order("users.email")

        render json: {
          staff: assignments.map { |assignment| assignment_json(assignment) },
          roles: EventRoleAssignment::ROLE_DETAILS.map { |role, details|
            { role: role, label: details[:label], summary: details[:summary] }
          }
        }
      end

      def create
        email = params[:email].to_s.strip.downcase
        unless email.match?(URI::MailTo::EMAIL_REGEXP)
          return render_error("A valid email address is required")
        end

        role = params[:role].to_s
        return render_error(unknown_role_message(role)) unless EventRoleAssignment.roles.key?(role)

        user = User.find_by(email: email)
        account_created = user.nil?
        # Same as the web: staffing someone who has never signed in creates a
        # shell account now, and it links up on their first sign-in.
        user ||= begin
          User.create!(email: email, name: email.split("@").first.titleize)
        rescue ActiveRecord::RecordInvalid => e
          return render_error("Could not create an account for #{email}: #{e.record.errors.full_messages.to_sentence}")
        end

        assignment = @event.event_role_assignments.build(user: user, role: role)

        if assignment.save
          notify_new_staff_member(assignment)
          audit_api_change!(:add_team_member, assignment, metadata: { role: role })
          render json: {
            staff_member: assignment_json(assignment),
            account_created: account_created
          }, status: :created
        else
          render_error(assignment.errors.full_messages.to_sentence)
        end
      end

      def update
        role = params[:role].to_s
        return render_error(unknown_role_message(role)) unless EventRoleAssignment.roles.key?(role)

        if @assignment.update(role: role)
          audit_api_change!(:record_update, @assignment)
          render json: { staff_member: assignment_json(@assignment) }
        else
          render_error(@assignment.errors.full_messages.to_sentence)
        end
      end

      def destroy
        # A series role reaches every event in the series; the assignment row
        # here is a projection of it, so deleting the row would either do
        # nothing or silently contradict the series. Same refusal as the web.
        if @assignment.inherited_from_series?
          return render json: {
            error: "This person is a series #{@assignment.series_role} — their access is inherited from the series, " \
                   "so it can't be removed here. Manage them from the series members page."
          }, status: :conflict
        end

        @assignment.destroy!
        audit_api_change!(:remove_team_member, @assignment, changed_fields: {}, metadata: { role: @assignment.role })
        head :no_content
      end

      private

      # Staff management is admin-only on the web (EventStaffController#
      # require_event_admin_access); the same question, asked through Pundit.
      def authorize_event_access!
        authorize @event, :manage_staff?
      end

      def set_assignment
        @assignment = @event.event_role_assignments.includes(:user).find(params[:id])
      end

      def unknown_role_message(role)
        "#{role.presence || 'role'} is not a valid role. Valid roles: #{EventRoleAssignment.roles.keys.join(', ')}"
      end

      def assignment_json(assignment)
        user = assignment.user
        details = EventRoleAssignment::ROLE_DETAILS[assignment.role] || {}

        {
          id: assignment.id,
          role: assignment.role,
          role_label: details[:label] || assignment.role.humanize,
          inherited_from_series: assignment.inherited_from_series?,
          series_role: assignment.series_role,
          created_at: assignment.created_at.iso8601,
          user: {
            id: user.id,
            email: user.email,
            name: user.name,
            global_admin: user.global_admin?
          }
        }
      end

      # Let a new staff member know they have access. `added_by` is nil for an
      # API key — the mailer already handles that, and says nothing about who
      # added them rather than naming the token's owner, who may not have been
      # the one to make the call.
      def notify_new_staff_member(assignment)
        return if assignment.user_id == current_user&.id

        EventStaffMailer.added_to_event(assignment: assignment, added_by: current_user).deliver_later
      rescue StandardError => e
        Rails.logger.error("[EventStaffMailer] Failed to enqueue invite for assignment #{assignment.id}: #{e.class} - #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end
    end
  end
end
