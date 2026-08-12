# frozen_string_literal: true

# TEMPORARILY DISABLED - re-enable after emergency fix
# if Rails.env.production? || Rails.env.staging?
#   Console1984.config do |config|
#     # Ask for a reason when starting a console session
#     config.ask_for_session_reason = true
#
#     # Protected environments require authentication and session reasons
#     config.protected_environments = %w[production staging]
#
#     # URLs that contain sensitive data (protected from console access)
#     config.protected_urls = []
#
#     # Use the User model for console operator tracking
#     config.username_resolver = -> { ENV.fetch("CONSOLE1984_USER") { `whoami`.strip.presence || "unknown" } }
#   end
# end

# Configure audits1984 (web UI for viewing console sessions)
# Rails.application.config.audits1984.auditor_class = "User"
# Rails.application.config.audits1984.auditor_name_attribute = :name
# Rails.application.config.audits1984.base_controller_class = "ApplicationController"
