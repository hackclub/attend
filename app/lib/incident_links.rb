# Absolute links back to Attend for incident notifications (email, Slack).
module IncidentLinks
  module_function

  # Public-form IncidentReport → /admin/incidents/:id
  def report_url(report)
    Rails.application.routes.url_helpers.admin_incident_report_url(report, **url_options)
  end

  # Event-scoped Incident → /admin/events/:slug/incidents/:id
  def incident_url(incident)
    Rails.application.routes.url_helpers.admin_event_incident_url(incident.event, incident, **url_options)
  end

  def url_options
    Rails.application.config.action_mailer.default_url_options.presence ||
      { host: "attend.hackclub.com", protocol: "https" }
  end
end
