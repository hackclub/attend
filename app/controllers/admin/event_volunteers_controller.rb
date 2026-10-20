module Admin
  # Volunteers sit on the staff page so their training shows next to everyone
  # else's, but they get no access to the event (see EventVolunteer).
  class EventVolunteersController < BaseController
    before_action :require_event_selected
    before_action :require_event_admin_access

    def create
      email = params[:email].to_s.strip.downcase

      unless email.match?(URI::MailTo::EMAIL_REGEXP)
        redirect_to admin_event_staff_index_path(current_event), alert: "Please enter a valid email address."
        return
      end

      user = User.find_by(email: email) || User.create!(email: email, name: email.split("@").first.titleize)
      @record = current_event.event_volunteers.build(user: user, added_by: current_user)

      if @record.save
        TrainingMailer.volunteer_added(volunteer: @record).deliver_later unless user == current_user
        redirect_to admin_event_staff_index_path(current_event, anchor: "volunteers"), notice: "Volunteer added."
      else
        redirect_to admin_event_staff_index_path(current_event, anchor: "volunteers"), alert: @record.errors.full_messages.to_sentence
      end
    end

    def destroy
      @record = current_event.event_volunteers.find(params[:id])
      @record.destroy
      redirect_to admin_event_staff_index_path(current_event, anchor: "volunteers"), notice: "Volunteer removed."
    end

    private

    def require_event_admin_access
      return if current_user.global_admin?
      return if current_user.event_admin_for?(current_event)

      redirect_to admin_root_path, alert: "Only event admins can manage volunteers."
    end
  end
end
