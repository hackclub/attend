module Api
  module V1
    class BansController < BaseController
      requires_scope "bans:write"

      before_action :require_global_admin!
      before_action :set_paper_trail_whodunnit

      # One ban record covers every email belonging to the same person, so a
      # single call may list several. Mirrors the nested form in the admin UI.
      def create
        emails = submitted_emails
        return render_error("At least one email is required") if emails.empty?

        invalid = emails.reject { |email| email.match?(URI::MailTo::EMAIL_REGEXP) }
        return render_error("Invalid email format: #{invalid.join(', ')}") if invalid.any?

        expires_at = parsed_expires_at
        return render_error("expires_at must be an ISO 8601 timestamp") if expires_at == :invalid

        already_listed = BanEmail.where("LOWER(ban_emails.email) IN (?)", emails).includes(:ban)
        return render_already_listed(already_listed) if already_listed.any?

        ban = Ban.new(reason: params[:reason].presence, expires_at: expires_at, created_by: current_user)
        emails.each { |email| ban.ban_emails.build(email: email) }

        if ban.save
          log_ban_created(ban)
          render json: { ban: ban_json(ban) }, status: :created
        else
          render_error(ban.errors.full_messages.to_sentence)
        end
      end

      private

      # Accepts either `email` (one) or `emails` (many); duplicates within a
      # request collapse rather than tripping the uniqueness validation.
      def submitted_emails
        raw = params[:emails].presence || params[:email].presence
        Array.wrap(raw).map { |email| email.to_s.strip.downcase }.reject(&:blank?).uniq
      end

      # Returns nil when omitted (an indefinite ban) and :invalid when the
      # caller sent something unparseable, so a typo can't silently become one.
      # Strict ISO 8601 rather than Time.zone.parse, which happily reads a
      # partial date out of nonsense and would turn a typo into a real expiry.
      def parsed_expires_at
        return nil if params[:expires_at].blank?

        Time.zone.iso8601(params[:expires_at].to_s)
      rescue ArgumentError
        :invalid
      end

      # `ban_emails.email` is globally unique, revoked bans included, so an
      # already-listed email cannot be attached to a new ban. Point the caller
      # at the existing record instead of returning a bare validation error.
      def render_already_listed(ban_emails)
        render json: {
          error: "Already on the ban list: #{ban_emails.map(&:email).sort.join(', ')}",
          bans: ban_emails.map(&:ban).uniq.map { |ban| ban_json(ban) }
        }, status: :conflict
      end

      def require_global_admin!
        return if current_user&.global_admin?

        render json: { error: "Only global admins can manage the ban list" }, status: :forbidden
      end

      # Api::V1::BaseController descends from ActionController::API, so it
      # doesn't pick up ApplicationController's PaperTrail hook. Without this
      # the ban's version history would have no author.
      def set_paper_trail_whodunnit
        PaperTrail.request.whodunnit = current_user.id
      end

      # Api controllers get no equivalent of Admin::BaseController's
      # log_admin_action, so record the ban explicitly — this is the one action
      # in the app that blocks someone from every future event.
      def log_ban_created(ban)
        AuditLog.log!(
          action: "create",
          record: ban,
          actor: current_user,
          metadata: {
            ip: request.remote_ip,
            user_agent: request.user_agent,
            controller: controller_name,
            emails: ban.ban_emails.map(&:email)
          }
        )
      rescue => e
        Rails.logger.error("[Security] Failed to audit-log ban #{ban.id}: #{e.class} - #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        raise if Rails.env.local?
      end

      def ban_json(ban)
        {
          id: ban.id,
          emails: ban.ban_emails.map(&:email).sort,
          reason: ban.reason,
          status: ban.status,
          active: ban.active?,
          expires_at: ban.expires_at&.iso8601,
          revoked_at: ban.revoked_at&.iso8601,
          created_at: ban.created_at.iso8601,
          created_by: ban.created_by && { id: ban.created_by.id, name: ban.created_by.name }
        }
      end
    end
  end
end
