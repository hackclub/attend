class WalletPassUpdateService
  class << self
    def update_passes_for(participant_event)
      new(participant_event).update_all
    end
  end

  def initialize(participant_event)
    @participant_event = participant_event
  end

  def update_all
    update_apple_wallet
    update_google_wallet
  end

  def update_apple_wallet
    passes = Passkit::Pass.where(generator: @participant_event)
    return if passes.none?

    passes.find_each do |pass|
      pass.touch
      notify_apple_devices(pass)
    end
  end

  def update_google_wallet
    return unless google_wallet_configured?

    ticket = ::GoogleWallet::EventTicket.new(@participant_event)

    # Use the logging versions that capture errors
    class_result = ticket.send(:push_class_with_logging)
    object_result = ticket.send(:push_object_with_logging)

    Rails.logger.info("Google Wallet update for ParticipantEvent #{@participant_event.id}: class=#{class_result}, object=#{object_result}")
  rescue StandardError => e
    Rails.logger.error("Google Wallet update failed for ParticipantEvent #{@participant_event.id}: #{e.message}")
  end

  private

  def notify_apple_devices(pass)
    return unless apple_push_configured?

    pass.devices.find_each do |device|
      next if device.push_token.blank?

      send_apple_push_notification(device.push_token)
    end
  end

  def send_apple_push_notification(push_token)
    connection = apns_connection
    return unless connection

    notification = Apnotic::Notification.new(push_token)
    notification.topic = ENV["PASSKIT_PASS_TYPE_IDENTIFIER"]

    response = connection.push(notification)

    if response&.ok?
      Rails.logger.info("Apple Wallet push sent successfully to #{push_token[0..8]}...")
    else
      Rails.logger.warn("Apple Wallet push failed: #{response&.status} - #{response&.body}")
    end
  rescue StandardError => e
    Rails.logger.error("Apple Wallet push error: #{e.message}")
  ensure
    connection&.close
  end

  def apns_connection
    cert_path = ENV["PASSKIT_PRIVATE_P12_CERTIFICATE"]
    cert_pass = ENV["PASSKIT_CERTIFICATE_KEY"]

    return nil unless cert_path.present? && File.exist?(cert_path)

    Apnotic::Connection.new(
      cert_path: cert_path,
      cert_pass: cert_pass
    )
  end

  def apple_push_configured?
    ENV["PASSKIT_PRIVATE_P12_CERTIFICATE"].present? &&
      ENV["PASSKIT_PASS_TYPE_IDENTIFIER"].present?
  end

  def google_wallet_configured?
    GoogleWallet.configuration&.json_credentials.present? &&
      GoogleWallet.configuration&.issuer_id.present?
  rescue StandardError
    false
  end
end
