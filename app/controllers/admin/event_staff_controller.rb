module Admin
  class EventStaffController < BaseController
    before_action :require_event_selected
    before_action :require_event_admin_access
    before_action :set_event_role_assignment, only: [ :update, :destroy ]

    def index
      @event_role_assignments = current_event.event_role_assignments
        .includes(:user)
        .order("users.email")
      @volunteers = current_event.event_volunteers.includes(:user).order("users.email")
      @training_status = TrainingStatus.for_event(current_event)
    end

    def new
      @event_role_assignment = current_event.event_role_assignments.build
    end

    def create
      email = params[:email]&.strip&.downcase

      unless email.present? && email.match?(URI::MailTo::EMAIL_REGEXP)
        redirect_to admin_event_staff_index_path(current_event), alert: "Please enter a valid email address."
        return
      end

      user = User.find_by(email: email)
      newly_created = user.nil?
      user ||= User.create!(email: email, name: email.split("@").first.titleize)

      @event_role_assignment = current_event.event_role_assignments.build(
        user: user,
        role: event_role_assignment_params[:role]
      )

      if @event_role_assignment.save
        notify_new_staff_member(@event_role_assignment)
        notice = newly_created ? "Staff member added — account created for #{user.email}; it'll link up when they first sign in." : "Staff member added successfully."
        redirect_to admin_event_staff_index_path(current_event), notice: notice
      else
        render :new, status: :unprocessable_entity
      end
    end

    # Inline edit on the staff table: the console's role cell submits here and
    # gets the cell back, in read mode on success or still editing with the
    # error underneath on failure. Without Turbo it falls back to a redirect.
    def update
      role = event_role_assignment_params[:role].to_s
      error = role_change_refusal(@event_role_assignment)
      error ||= "Choose one of the listed roles." unless EventRoleAssignment.roles.key?(role)

      if error.nil? && @event_role_assignment.update(role: role)
        respond_to do |format|
          format.turbo_stream { render_role_cell(saved: true) }
          format.html { redirect_to admin_event_staff_index_path(current_event), notice: "#{@event_role_assignment.user.email} is now #{role_label(role)}." }
        end
      else
        error ||= role_change_error_message(@event_role_assignment, role)
        @event_role_assignment.restore_attributes
        respond_to do |format|
          format.turbo_stream { render_role_cell(error: error, attempted_role: role, status: :unprocessable_entity) }
          format.html { redirect_to admin_event_staff_index_path(current_event), alert: error }
        end
      end
    end

    def destroy
      if @event_role_assignment.inherited_from_series?
        redirect_to admin_event_staff_index_path(current_event),
          alert: "#{@event_role_assignment.user.email} is a series #{@event_role_assignment.series_role} — their access is inherited from the series, so they can't be removed here. Manage them from the series members page."
        return
      end

      @event_role_assignment.destroy
      redirect_to admin_event_staff_index_path(current_event), notice: "Staff member removed."
    end

    private

    def set_event_role_assignment
      @event_role_assignment = current_event.event_role_assignments.find(params[:id])
    end

    def event_role_assignment_params
      params.require(:event_role_assignment).permit(:role)
    end

    # Why this row's role can't be changed here, or nil when it can. The index
    # uses the same check to lock the cell, so the two can't disagree.
    def role_change_refusal(assignment)
      if assignment.inherited_from_series?
        "Series #{assignment.series_role}s are event admins on every event in the series. Change their role from the series members page."
      elsif assignment.user_id == current_user.id && !current_user.global_admin?
        "You can't change your own role. Ask another event admin."
      end
    end
    helper_method :role_change_refusal

    def role_change_error_message(assignment, role)
      if assignment.errors.of_kind?(:role, :taken)
        "#{assignment.user.email} already has the #{role_label(role)} role on this event."
      else
        assignment.errors.full_messages.to_sentence.presence || "The role couldn't be changed."
      end
    end

    def role_label(role)
      EventRoleAssignment::ROLE_DETAILS.dig(role.to_s, :label) || role.to_s.titleize
    end

    def render_role_cell(saved: false, error: nil, attempted_role: nil, status: :ok)
      render turbo_stream: turbo_stream.replace(
        helpers.dom_id(@event_role_assignment, :role_cell),
        partial: "admin/event_staff/role_cell",
        locals: { assignment: @event_role_assignment, saved: saved, error: error, attempted_role: attempted_role }
      ), status: status
    end

    def require_event_admin_access
      return if current_user.global_admin?
      return if current_user.event_admin_for?(current_event)

      redirect_to admin_root_path, alert: "Only event admins can manage staff."
    end
  end
end
