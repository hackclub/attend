module Api
  module V1
    # Hack Club Auth's session revoker for Attend's app. When someone loses an
    # HCA directory entitlement exposed to Attend (or their account is
    # locked), HCA POSTs {"email": "..."} here with
    # `Authorization: Bearer <secret>` and retries for a few hours on anything
    # but a 2xx.
    #
    # The only thing Attend takes from those entitlements is the `groups`
    # claim (User#hca_groups), which is otherwise read once at sign-in. So
    # this drops it: whatever it granted (self-serve event creation) stops at
    # once, without signing the person out of the rest of Attend, and their
    # next sign-in brings back whatever they still hold.
    class HackClubAuthRevocationsController < ActionController::API
      before_action :authenticate!

      def create
        # No address, or nobody here under it, is nothing to revoke; answering
        # 2xx keeps HCA from retrying it for hours.
        email = params[:email].to_s.strip.downcase
        if email.blank?
          Rails.logger.warn("[HCA revoker] request with no email; nothing to revoke")
          return head(:no_content)
        end

        user = User.find_by(email: email)
        if user && user.hca_groups.any?
          user.with_lock { user.update!(oidc_claims: user.oidc_claims.except("groups")) }
          Rails.logger.info("[HCA revoker] dropped groups for user #{user.id}")
        end

        head :no_content
      end

      private

      def authenticate!
        expected = ENV["HACK_CLUB_AUTH_REVOKER_SECRET"].presence ||
          Rails.application.credentials.dig(:hack_club, :revoker_secret).presence
        provided = request.authorization.to_s[/\ABearer (.+)\z/, 1]

        if expected.blank?
          Rails.logger.error("[HCA revoker] no revoker secret configured; refusing")
          return head(:unauthorized)
        end

        head(:unauthorized) unless provided.present? && ActiveSupport::SecurityUtils.secure_compare(
          ::Digest::SHA256.hexdigest(provided), ::Digest::SHA256.hexdigest(expected)
        )
      end
    end
  end
end
