module Admin
  class SettingsController < BaseController
    global_page
    before_action :require_global_admin

    SLACK_CHANNEL_ID = /\A[CG][A-Z0-9]+\z/
    TWILIO_VERIFY_SERVICE_SID = /\AVA[0-9a-f]{32}\z/

    # The General tab: the app-wide switches. The original admin keeps
    # everything on this one page.
    def show
      load_settings
    end

    # Twilio, WhatsApp and the Slack channels, split off from General so a
    # credential isn't one click away from maintenance mode.
    def integrations
      unless helpers.console_ui?
        flash.keep
        return redirect_to admin_settings_path
      end

      load_settings
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
        redirect_to integrations_admin_settings_path, alert: "Please set a valid phone number before enabling Twilio SMS."
        return
      end

      Setting.twilio_enabled = new_state

      redirect_to integrations_admin_settings_path,
        notice: "Twilio SMS #{new_state ? 'enabled' : 'disabled'}."
    end

    def update_twilio_from_number
      Setting.twilio_from_number = params[:twilio_from_number]
      redirect_to integrations_admin_settings_path, notice: "Twilio phone number updated."
    end

    def update_twilio_verify
      sid = params[:twilio_verify_service_sid].to_s.strip

      if sid.present? && !sid.match?(TWILIO_VERIFY_SERVICE_SID)
        redirect_to integrations_admin_settings_path, alert: "That doesn't look like a Verify service SID. It should start with VA."
        return
      end

      Setting.twilio_verify_service_sid = sid
      Setting.twilio_verify_whatsapp = params[:twilio_verify_whatsapp] == "1"
      redirect_to integrations_admin_settings_path, notice: "Twilio Verify settings updated."
    end

    def toggle_whatsapp
      new_state = !Setting.whatsapp_enabled?
      Setting.whatsapp_enabled = new_state

      redirect_to integrations_admin_settings_path,
        notice: "WhatsApp messages #{new_state ? 'enabled' : 'disabled'}."
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
        redirect_to integrations_admin_settings_path, alert: "Add at least one phone number before enabling support SMS notifications."
        return
      end

      Setting.support_sms_notifications_enabled = new_state

      redirect_to integrations_admin_settings_path,
        notice: "Support SMS notifications #{new_state ? 'enabled' : 'disabled'}."
    end

    def update_support_sms_numbers
      numbers = params[:support_sms_notification_numbers].to_s.split(/[\n,;]+/)
                      .map { |n| n.gsub(/[^\d+]/, "") }.reject(&:blank?)

      invalid = numbers.reject { |n| valid_phone_number?(n) }
      if invalid.any?
        redirect_to integrations_admin_settings_path, alert: "Invalid phone number: #{invalid.join(', ')}. Use E.164 format, e.g. +14155551234."
        return
      end

      Setting.support_sms_notification_numbers = numbers
      redirect_to integrations_admin_settings_path, notice: "Support SMS notification numbers updated."
    end

    def update_admin_help_slack_channel
      channel_id = params[:admin_help_slack_channel_id].to_s.strip
      unless channel_id.blank? || channel_id.match?(SLACK_CHANNEL_ID)
        redirect_to integrations_admin_settings_path, alert: "That doesn't look like a Slack channel ID (e.g. C0123ABCD)."
        return
      end

      Setting.admin_help_slack_channel_id = channel_id
      redirect_to integrations_admin_settings_path, notice: "Admin help channel updated."
    end

    def sync_admin_help_slack_channel
      if Setting.admin_help_slack_channel_id.blank?
        redirect_to integrations_admin_settings_path, alert: "Set the admin help channel ID before syncing."
        return
      end

      SyncAdminHelpSlackChannelJob.perform_later
      redirect_to integrations_admin_settings_path,
        notice: "Syncing global and active event admins to the Slack channel. Refresh in a minute to see the results."
    end

    def update_org_support_slack_channel
      channel_id = params[:org_support_slack_channel_id].to_s.strip
      unless channel_id.blank? || channel_id.match?(SLACK_CHANNEL_ID)
        redirect_to integrations_admin_settings_path, alert: "That doesn't look like a Slack channel ID (e.g. C0123ABCD)."
        return
      end

      Setting.org_support_slack_channel_id = channel_id
      redirect_to integrations_admin_settings_path, notice: "Org support channel updated."
    end

    def sync_org_support_slack_channel
      if Setting.org_support_slack_channel_id.blank?
        redirect_to integrations_admin_settings_path, alert: "Set the org support channel ID before syncing."
        return
      end

      SyncOrgSupportSlackChannelJob.perform_later
      redirect_to integrations_admin_settings_path,
        notice: "Syncing admins to the org support Slack channel. Refresh in a minute to see the results."
    end

    private

    def load_settings
      @maintenance_mode = Setting.maintenance_mode?
      @twilio_enabled = Setting.twilio_enabled?
      @twilio_from_number = Setting.twilio_from_number
      @twilio_verify_service_sid = Setting.twilio_verify_service_sid
      @twilio_verify_whatsapp = Setting.twilio_verify_whatsapp?
      @whatsapp_enabled = Setting.whatsapp_enabled?
      @waiver_sending_paused = Setting.waiver_sending_paused?
      @support_sms_notifications_enabled = Setting.support_sms_notifications_enabled?
      @support_sms_notification_numbers = Setting.support_sms_notification_number_list
      @admin_help_slack_channel_id = Setting.admin_help_slack_channel_id
      admin_help_members = User.admin_help_channel_members
      @admin_help_member_count = admin_help_members.count
      @admin_help_members_without_slack = admin_help_members.where(verified_slack_id: nil).count
      @admin_help_last_sync = Setting.admin_help_slack_last_sync
      @org_support_slack_channel_id = Setting.org_support_slack_channel_id
      org_support_members = User.org_support_channel_members
      @org_support_member_count = org_support_members.count
      @org_support_members_without_slack = org_support_members.where(verified_slack_id: nil).count
      @org_support_last_sync = Setting.org_support_slack_last_sync
    end

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
