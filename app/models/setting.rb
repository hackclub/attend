class Setting < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  validates :key, presence: true, uniqueness: true

  MAINTENANCE_MODE = "maintenance_mode".freeze
  TWILIO_ENABLED = "twilio_enabled".freeze
  TWILIO_FROM_NUMBER = "twilio_from_number".freeze
  WAIVER_SENDING_PAUSED = "waiver_sending_paused".freeze
  INCIDENT_REPORTS_SLACK_CHANNEL_ID = "incident_reports_slack_channel_id".freeze
  INCIDENT_REPORTS_RESPONDER_USER_IDS = "incident_reports_responder_user_ids".freeze
  INCIDENT_REPORTS_CUSTOM_EVENTS = "incident_reports_custom_events".freeze
  SUPPORT_SMS_NOTIFICATIONS_ENABLED = "support_sms_notifications_enabled".freeze
  SUPPORT_SMS_NOTIFICATION_NUMBERS = "support_sms_notification_numbers".freeze

  class << self
    def maintenance_mode?
      get(MAINTENANCE_MODE) == "true"
    end

    def maintenance_mode=(enabled)
      set(MAINTENANCE_MODE, enabled.to_s)
    end

    def twilio_enabled?
      get(TWILIO_ENABLED) == "true"
    end

    def twilio_enabled=(enabled)
      set(TWILIO_ENABLED, enabled.to_s)
    end

    def twilio_from_number
      get(TWILIO_FROM_NUMBER)
    end

    def twilio_from_number=(number)
      set(TWILIO_FROM_NUMBER, number.to_s.gsub(/\s/, ""))
    end

    def waiver_sending_paused?
      get(WAIVER_SENDING_PAUSED) == "true"
    end

    def waiver_sending_paused=(enabled)
      set(WAIVER_SENDING_PAUSED, enabled.to_s)
    end

    def incident_reports_slack_channel_id
      get(INCIDENT_REPORTS_SLACK_CHANNEL_ID).presence
    end

    def incident_reports_slack_channel_id=(channel_id)
      set(INCIDENT_REPORTS_SLACK_CHANNEL_ID, channel_id.to_s.strip)
    end

    def incident_reports_responder_user_ids=(ids)
      set(INCIDENT_REPORTS_RESPONDER_USER_IDS, Array(ids).reject(&:blank?).uniq.join(","))
    end

    def incident_reports_responder_user_id_list
      get(INCIDENT_REPORTS_RESPONDER_USER_IDS).to_s.split(",").map(&:strip).reject(&:blank?)
    end

    # The selected responder users (preserving any that are still global admins).
    def incident_responders
      ids = incident_reports_responder_user_id_list
      return User.none if ids.empty?

      User.where(id: ids)
    end

    # Recipient lists derived from responder profiles.
    def incident_reports_notify_email_list
      incident_responders.map(&:email).compact.uniq
    end

    def incident_reports_slack_dm_user_id_list
      incident_responders.filter_map(&:slack_id).uniq
    end

    def incident_reports_custom_events=(value)
      set(INCIDENT_REPORTS_CUSTOM_EVENTS, value.to_s.strip)
    end

    def incident_reports_custom_events
      get(INCIDENT_REPORTS_CUSTOM_EVENTS).presence
    end

    # Names of past events that never ran on Attend, for the incident form.
    def incident_reports_custom_event_list
      incident_reports_custom_events.to_s.split(/[\n;]+/).map(&:strip).reject(&:blank?).uniq
    end

    # [{ name:, phone: }] for everyone whose profile has a phone number.
    def incident_reports_emergency_phone_list
      incident_responders.filter_map do |user|
        phone = user.phone.to_s.gsub(/[^\d+]/, "")
        next if phone.blank?

        { name: user.display_name_or_fallback, phone: phone }
      end
    end

    def support_sms_notifications_enabled?
      get(SUPPORT_SMS_NOTIFICATIONS_ENABLED) == "true"
    end

    def support_sms_notifications_enabled=(enabled)
      set(SUPPORT_SMS_NOTIFICATIONS_ENABLED, enabled.to_s)
    end

    def support_sms_notification_numbers=(numbers)
      list = Array(numbers).flat_map { |n| n.to_s.split(/[\n,;]+/) }
                           .map { |n| n.gsub(/[^\d+]/, "") }
                           .reject(&:blank?).uniq
      set(SUPPORT_SMS_NOTIFICATION_NUMBERS, list.join(","))
    end

    # E.164 numbers texted when a new inbound support ticket is opened.
    def support_sms_notification_number_list
      get(SUPPORT_SMS_NOTIFICATION_NUMBERS).to_s.split(",").map(&:strip).reject(&:blank?)
    end

    def get(key)
      find_by(key: key)&.value
    end

    def set(key, value)
      setting = find_or_initialize_by(key: key)
      setting.update!(value: value)
      setting
    end
  end
end
