module Api
  module V1
    # Leaked-token kill switch.
    #
    # A caller proves authorization by presenting the token's own secret value:
    # holding the secret is the only thing needed to revoke it (mirrors how
    # GitHub et al. handle leaked-credential revocation). Without a valid secret
    # the request is a no-op, so this endpoint cannot be used to disable
    # arbitrary integrations. No other authentication is required — in
    # particular, Revoker (https://revoke.hackclub.com) calls this with no
    # credentials beyond the leaked token itself.
    #
    # The response follows Revoker's contract: { success:, owner_email:,
    # key_name: } for a valid token, { success: false } otherwise. Anyone
    # presenting a valid secret could already act as that token, so revealing
    # the owner's email to them leaks nothing they couldn't get through the
    # API — and the token is dead by the time they see it. Attend also emails
    # the owner on every successful revocation, since it can't tell whether the
    # caller (e.g. Revoker) sends its own notification.
    #
    # Handles all three token kinds: GlobalApiToken, EventApiToken, and the
    # legacy single Event#api_key.
    class TokenRevocationsController < ActionController::API
      # Deliberately no authenticate_token! — this endpoint is public by design.

      def create
        token = params[:token].to_s.strip
        result = token.present? ? revoke_token(token) : nil

        if result
          render json: {
            success: true,
            owner_email: result[:owner_email],
            key_name: result[:key_name]
          }
        else
          render json: { success: false }
        end
      end

      private

      # Returns details about the revoked token, or nil if the token was not
      # valid/active. Emails the owner on every successful revocation.
      def revoke_token(token)
        if (global_token = GlobalApiToken.find_by_token(token))
          global_token.revoke!
          owner = global_token.user&.email
          send_email([ owner ], token_name: global_token.name, kind: "global")
          return { owner_email: owner, key_name: global_token.name }
        end

        if (event_token = EventApiToken.find_by_token(token))
          event_token.revoke!
          event = event_token.event
          owner = event_token.user&.email
          recipients = [ owner ].compact.presence || event_admin_emails(event)
          send_email(recipients, token_name: event_token.name, kind: "event", event_name: event.name)
          return {
            owner_email: owner || recipients.first,
            key_name: "#{event_token.name} (#{event.name})"
          }
        end

        if (event = Event.find_by_api_key(token))
          # Legacy single event key: revoking means clearing its digest.
          event.update!(api_key_digest: nil)
          admins = event_admin_emails(event)
          send_email(admins, token_name: "Legacy API key", kind: "event", event_name: event.name)
          return { owner_email: admins.first, key_name: "Legacy API key (#{event.name})" }
        end

        nil
      end

      def event_admin_emails(event)
        event.event_role_assignments.event_admin.includes(:user).filter_map { |a| a.user&.email }
      end

      def send_email(emails, token_name:, kind:, event_name: nil)
        emails.compact.uniq.each do |email|
          next if email.blank?

          ApiTokenMailer.with(
            email: email,
            token_name: token_name,
            token_kind: kind,
            event_name: event_name
          ).revoked.deliver_later
        end
      end
    end
  end
end
