module Api
  module V1
    # An event's volunteer roster — the API equivalent of the Volunteers card
    # on the staff page (Admin::EventVolunteersController).
    #
    # A volunteer gets no access to the event (see EventVolunteer); being on
    # the roster only means a training invite and a training flag on the staff
    # page. That's why this is looser than the staff endpoints: anyone with a
    # role on the event may manage it, same as the web, and an API key may
    # manage it for the events it reaches — its own event for an event key,
    # every event in its series for a series key.
    class EventVolunteersController < BaseController
      include Pundit::Authorization
      include Api::V1::EventScoped
      include Api::V1::ApiAuditing

      def index
        volunteers = @event.event_volunteers.includes(:user).order("users.email")
        training = TrainingStatus.for_event(@event, include_ineligible: show_ineligible?)

        render json: {
          volunteers: volunteers.map { |volunteer| volunteer_json(volunteer, training.for(volunteer.user_id)) }
        }
      end

      def create
        email = params[:email].to_s.strip.downcase
        unless email.match?(URI::MailTo::EMAIL_REGEXP)
          return render_error("A valid email address is required")
        end

        user = User.find_by(email: email)
        account_created = user.nil?
        # Same as the web: someone who has never signed in gets a shell
        # account now, which links up on their first sign-in (or their first
        # emailed-code sign-in to training).
        user ||= begin
          User.create!(email: email, name: email.split("@").first.titleize)
        rescue ActiveRecord::RecordInvalid => e
          return render_error("Could not create an account for #{email}: #{e.record.errors.full_messages.to_sentence}")
        end

        # added_by is nil for an API key: the mailer then says nothing about who
        # added them, rather than naming the key's owner, who may not have been
        # the one to make the call.
        volunteer = @event.event_volunteers.build(user: user, added_by: current_user)

        if volunteer.save
          notify_volunteer(volunteer)
          audit_api_change!(:record_create, volunteer)
          render json: {
            volunteer: volunteer_json(volunteer, TrainingStatus.for_user_at_event(user, @event)),
            account_created: account_created
          }, status: :created
        else
          render_error(volunteer.errors.full_messages.to_sentence)
        end
      rescue ActiveRecord::RecordNotUnique
        # Two calls for the same email racing past the uniqueness validation;
        # the unique index catches the second.
        render_error("User is already a volunteer at this event")
      end

      def destroy
        volunteer = @event.event_volunteers.find(params[:id])
        volunteer.destroy!
        audit_api_change!(:record_destroy, volunteer, changed_fields: {})
        head :no_content
      end

      private

      # Ineligibility comes from criminal-record declarations, so the web only
      # shows it to people who manage the event's staff. An API key has no
      # person behind it to ask, so it never sees it.
      def show_ineligible?
        current_user.present? && EventPolicy.new(current_user, @event).manage_staff?
      end

      def volunteer_json(volunteer, status)
        user = volunteer.user

        {
          id: volunteer.id,
          created_at: volunteer.created_at.iso8601,
          user: {
            id: user.id,
            email: user.email,
            name: user.name
          },
          training: {
            state: status.state.to_s,
            missing: status.missing.map(&:name)
          }
        }
      end

      def notify_volunteer(volunteer)
        return if volunteer.user_id == current_user&.id

        TrainingMailer.volunteer_added(volunteer: volunteer).deliver_later
      rescue StandardError => e
        Rails.logger.error("[TrainingMailer] Failed to enqueue volunteer email for #{volunteer.id}: #{e.class} - #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end
    end
  end
end
