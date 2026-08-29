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
