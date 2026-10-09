module Admin
  class SettingsController < BaseController
    before_action :require_global_admin

    def show
      @maintenance_mode = Setting.maintenance_mode?
      @twilio_enabled = Setting.twilio_enabled?
      @twilio_from_number = Setting.twilio_from_number
      @waiver_sending_paused = Setting.waiver_sending_paused?
      @support_sms_notifications_enabled = Setting.support_sms_notifications_enabled?
      @support_sms_notification_numbers = Setting.support_sms_notification_number_list
      @admin_help_slack_channel_id = Setting.admin_help_slack_channel_id
      admin_help_members = User.admin_help_channel_members.to_a
      @admin_help_member_count = admin_help_members.size
      @admin_help_members_without_slack = admin_help_members.count { |user| user.slack_id.blank? }
      @admin_help_last_sync = Setting.admin_help_slack_last_sync
    end

    def toggle_maintenance
      new_state = !Setting.maintenance_mode?
      Setting.maintenance_mode = new_state

      redirect_to admin_settings_path,
        notice: "Maintenance mode #{new_state ? 'enabled' : 'disabled'}."
    end

    def toggle_twilio
      new_state = !Setting.twilio_enabled?

      if new_state && !valid_phone_number?(Setting.twilio_from_number)
        redirect_to admin_settings_path, alert: "Please set a valid phone number before enabling Twilio SMS."
        return
      end

      Setting.twilio_enabled = new_state

      redirect_to admin_settings_path,
        notice: "Twilio SMS #{new_state ? 'enabled' : 'disabled'}."
    end

    def update_twilio_from_number
      Setting.twilio_from_number = params[:twilio_from_number]
      redirect_to admin_settings_path, notice: "Twilio phone number updated."
    end

    def toggle_waiver_sending
      new_state = !Setting.waiver_sending_paused?
      Setting.waiver_sending_paused = new_state

      if !new_state
        ProcessPausedWaiversJob.perform_later
      end

      redirect_to admin_settings_path,
        notice: "Waiver sending #{new_state ? 'paused' : 'resumed. Processing backlog of paused waivers.'}."
    end

    def toggle_support_sms
      new_state = !Setting.support_sms_notifications_enabled?

      if new_state && Setting.support_sms_notification_number_list.empty?
        redirect_to admin_settings_path, alert: "Add at least one phone number before enabling support SMS notifications."
        return
      end

      Setting.support_sms_notifications_enabled = new_state

      redirect_to admin_settings_path,
        notice: "Support SMS notifications #{new_state ? 'enabled' : 'disabled'}."
    end

    def update_support_sms_numbers
      numbers = params[:support_sms_notification_numbers].to_s.split(/[\n,;]+/)
                      .map { |n| n.gsub(/[^\d+]/, "") }.reject(&:blank?)

      invalid = numbers.reject { |n| valid_phone_number?(n) }
      if invalid.any?
        redirect_to admin_settings_path, alert: "Invalid phone number: #{invalid.join(', ')}. Use E.164 format, e.g. +14155551234."
        return
      end

      Setting.support_sms_notification_numbers = numbers
      redirect_to admin_settings_path, notice: "Support SMS notification numbers updated."
    end

    def update_admin_help_slack_channel
      channel_id = params[:admin_help_slack_channel_id].to_s.strip
      unless channel_id.blank? || channel_id.match?(/\A[CG][A-Z0-9]+\z/)
        redirect_to admin_settings_path, alert: "That doesn't look like a Slack channel ID (e.g. C0123ABCD)."
        return
      end

      Setting.admin_help_slack_channel_id = channel_id
      redirect_to admin_settings_path, notice: "Admin help channel updated."
    end

    def sync_admin_help_slack_channel
      if Setting.admin_help_slack_channel_id.blank?
        redirect_to admin_settings_path, alert: "Set the admin help channel ID before syncing."
        return
      end

      SyncAdminHelpSlackChannelJob.perform_later
      redirect_to admin_settings_path,
        notice: "Syncing global and active event admins to the Slack channel. Refresh in a minute to see the results."
    end

    private

    def require_global_admin
      unless current_user&.global_admin?
        redirect_to admin_root_path, alert: "You must be a global admin to access settings."
      end
    end

    # `default_country: nil` keeps this strict E.164 — an outbound sender
    # number typed without a country code must be rejected, not guessed at.
    def valid_phone_number?(number)
      PhoneNormalizer.valid?(number, default_country: nil)
    end
  end
end
