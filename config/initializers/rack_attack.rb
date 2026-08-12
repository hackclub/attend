# Skip Rack::Attack configuration if database isn't ready (e.g., during db:prepare)
return unless ActiveRecord::Base.connection.table_exists?("solid_cache_entries") rescue false

class Rack::Attack
  throttle("req/ip", limit: 300, period: 5.minutes) do |req|
    req.ip unless req.path.start_with?("/assets")
  end

  throttle("logins/ip", limit: 5, period: 20.seconds) do |req|
    if req.path == "/users/sign_in" && req.post?
      req.ip
    end
  end

  throttle("logins/email", limit: 5, period: 20.seconds) do |req|
    if req.path == "/users/sign_in" && req.post?
      req.params["user"]["email"].to_s.downcase.gsub(/\s+/, "").presence
    end
  end

  throttle("guardian/invite", limit: 10, period: 1.minute) do |req|
    if req.path.start_with?("/guardian/invite") && req.get?
      req.ip
    end
  end

  throttle("api/participants", limit: 60, period: 1.minute) do |req|
    if req.path == "/api/v1/participants" && req.post?
      req.ip
    end
  end

  throttle("api/webhooks", limit: 100, period: 1.minute) do |req|
    if req.path.start_with?("/api/v1/webhooks")
      req.ip
    end
  end

  blocklist("fail2ban/login") do |req|
    Rack::Attack::Fail2Ban.filter("login-#{req.ip}", maxretry: 10, findtime: 10.minutes, bantime: 1.hour) do
      req.path == "/users/sign_in" && req.post?
    end
  end
end

ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |name, start, finish, request_id, payload|
  Rails.logger.warn "[Rack::Attack] Throttled #{payload[:request].ip} - #{payload[:request].path}"
end
