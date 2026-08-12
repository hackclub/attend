module Admin
  class EventStaffController < BaseController
    before_action :require_event_selected
    before_action :require_event_admin_access
    before_action :set_event_role_assignment, only: [ :destroy ]

    def index
      @event_role_assignments = current_event.event_role_assignments
        .includes(:user)
        .order("users.email")
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

    def destroy
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

    def require_event_admin_access
      return if current_user.global_admin?
      return if current_user.event_admin_for?(current_event)

      redirect_to admin_root_path, alert: "Only event admins can manage staff."
    end
  end
end
