# Explaining the S0–S3 scale wherever an incident level shows up.
module IncidentLevelsHelper
  # The organizer doc with HQ's triage chart; the docs are served by this app.
  INCIDENT_LEVELS_DOCS_PATH = "/docs/organizers/reporting-incidents#the-levels".freeze

  def incident_levels_docs_path
    INCIDENT_LEVELS_DOCS_PATH
  end

  # "High priority · ≈ 5 minutes" for showing beside a badge.
  def incident_level_text(key)
    level = IncidentLevel.find(key)
    level ? "#{level.name} · #{level.target}" : nil
  end
end
