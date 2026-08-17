# Skip passkit configuration during asset precompilation or if not configured
passkit_config = Rails.application.credentials.dig(:passkit)

if passkit_config.present? && !ENV["SECRET_KEY_BASE_DUMMY"]
  # Set ENV vars that the passkit gem expects (it reads from ENV internally)
  ENV["PASSKIT_CERTIFICATE_KEY"] = passkit_config[:certificate_key]
  ENV["PASSKIT_APPLE_TEAM_IDENTIFIER"] = passkit_config[:apple_team_identifier]
  ENV["PASSKIT_PASS_TYPE_IDENTIFIER"] = passkit_config[:pass_type_identifier]

  ENV["PASSKIT_WEB_SERVICE_HOST"] = if Rails.env.development?
    "https://attend.local"
  else
    passkit_config[:web_service_host]
  end

  if Rails.env.development?
    ENV["PASSKIT_PRIVATE_P12_CERTIFICATE"] = Rails.root.join("certs", "certificate.p12").to_s
    ENV["PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE"] = Rails.root.join("certs", "WWDR.cer").to_s
  else
    # In production, decode base64-encoded certificates from credentials and write to temp files
    cert_dir = Rails.root.join("tmp", "certs")
    FileUtils.mkdir_p(cert_dir)

    p12_path = cert_dir.join("certificate.p12")
    File.binwrite(p12_path, Base64.decode64(passkit_config[:private_p12_certificate_base64]))
    ENV["PASSKIT_PRIVATE_P12_CERTIFICATE"] = p12_path.to_s

    wwdr_path = cert_dir.join("WWDR.cer")
    File.binwrite(wwdr_path, Base64.decode64(passkit_config[:apple_intermediate_certificate_base64]))
    ENV["PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE"] = wwdr_path.to_s
  end

  Passkit.configure do |config|
    # config.available_passes['Passkit::YourPass'] = -> { User.create }
  end
else
  # Passkit::Generator resolves these paths when the class is loaded
  # (Rails.root.join(ENV[...]) at the class body), so leaving them nil turns a
  # missing passkit config into a boot failure instead of just an app without
  # wallet passes. Point them at paths that do not exist: booting works, and
  # generating a pass raises with a readable Errno::ENOENT.
  #
  # This must run during asset precompilation too. Zeitwerk eager-loads the
  # class then as well, so gating this branch on SECRET_KEY_BASE_DUMMY — as the
  # branch above is, because it has real certificates to write — left the paths
  # nil in exactly the case that has no credentials to fall back on.
  ENV["PASSKIT_PRIVATE_P12_CERTIFICATE"] ||= "tmp/certs/missing-certificate.p12"
  ENV["PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE"] ||= "tmp/certs/missing-WWDR.cer"

  Rails.logger&.warn("[passkit] no :passkit credentials — wallet passes are disabled") unless ENV["SECRET_KEY_BASE_DUMMY"]
end
