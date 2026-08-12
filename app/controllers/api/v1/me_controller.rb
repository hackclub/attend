module Api
  module V1
    class MeController < BaseController
      def show
        render json: {
          id: current_user.id,
          email: current_user.email,
          name: current_user.name,
          global_admin: current_user.global_admin?,
          is_organizer: organizer?,
          is_participant: current_user.participant.present?
        }
      end

      private

      # A user is an "organizer" if they have any staff-level access: either a
      # global admin, or an event role assignment on at least one event. The
      # mobile app uses this to decide whether to show the scanner experience.
      def organizer?
        current_user.global_admin? || current_user.event_role_assignments.exists?
      end
    end
  end
end
