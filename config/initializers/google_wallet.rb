# Skip Google Wallet configuration during asset precompilation or if not configured
google_wallet_config = Rails.application.credentials.dig(:google_wallet)

if google_wallet_config.present? && !ENV["SECRET_KEY_BASE_DUMMY"]
  GoogleWallet.configure do |config|
    # Load credentials from JSON string or file path
    if google_wallet_config[:credentials_json].present?
      # Write JSON to a persistent file since gem only supports file loading
      # Using tmp/certs to avoid tempfile being garbage collected
      credentials_dir = Rails.root.join("tmp", "certs")
      FileUtils.mkdir_p(credentials_dir)
      credentials_path = credentials_dir.join("google_wallet_credentials.json")
      File.write(credentials_path, google_wallet_config[:credentials_json])
      config.load_credentials_from_file(credentials_path.to_s)
    elsif google_wallet_config[:credentials_file].present?
      config.load_credentials_from_file(google_wallet_config[:credentials_file])
    end

    config.issuer_id = google_wallet_config[:issuer_id]
    config.debug_mode = Rails.env.development?
    config.logger = Rails.logger
  end
end
