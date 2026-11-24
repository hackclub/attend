module Api
  module V1
    # What a scanner needs to check signed check-in codes on the device, so
    # the mobile app can turn away a forged ticket with no connection: the
    # public keys (see CheckinCode) and the registrations whose tickets no
    # longer count. Ids and public keys only; nothing personal.
    class CheckinCodesController < BaseController
      before_action :set_event
      before_action :require_event_access

      def show
        render json: {
          signing: CheckinCode.signing_enabled?,
          keys: CheckinCode.public_keys,
          cancelled: CheckinCode.cancelled_registration_ids(@event)
        }
      end

      private

      def set_event
        @event = Event.find(params[:event_id])
      end

      def require_event_access
        require_event_access!(@event)
      end
    end
  end
end
