module Admin
  class SeriesMembersController < BaseController
    before_action :set_series
    before_action :require_series_owner_access

    def index
      @series_role_assignments = @series.series_role_assignments
        .includes(:user)
        .order("users.email")
    end

    def new
      @series_role_assignment = @series.series_role_assignments.build
    end

    def create
      email = params[:email]&.strip&.downcase

      unless email.present? && email.match?(URI::MailTo::EMAIL_REGEXP)
        redirect_to admin_series_members_path(@series), alert: "Please enter a valid email address."
        return
      end

      user = User.find_by(email: email)
      newly_created = user.nil?
      user ||= User.create!(email: email, name: email.split("@").first.titleize)

      @series_role_assignment = @series.series_role_assignments.build(
        user: user,
        role: series_role_assignment_params[:role]
      )

      if @series_role_assignment.save
        notice = newly_created ? "Member added — account created for #{user.email}; it'll link up when they first sign in." : "Member added successfully."
        redirect_to admin_series_members_path(@series), notice: notice
      else
        render :new, status: :unprocessable_entity
      end
    end

    def destroy
      @series_role_assignment = @series.series_role_assignments.find(params[:id])
      @series_role_assignment.destroy
      redirect_to admin_series_members_path(@series), notice: "Member removed."
    end

    private

    def set_series
      @series = EventSeries.find_by!(slug: params[:series_slug])
    end

    def series_role_assignment_params
      params.require(:series_role_assignment).permit(:role)
    end

    def require_series_owner_access
      return if policy(@series).manage_members?

      redirect_to admin_series_path(@series), alert: "Only series owners can manage members."
    end
  end
end
