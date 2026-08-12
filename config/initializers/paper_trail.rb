PaperTrail.config.enabled = true
PaperTrail.config.has_paper_trail_defaults = {
  on: %i[create update destroy]
}

PaperTrail.config.version_limit = 50

# PaperTrail's YAML serializer uses safe_load, which rejects classes like
# ActiveSupport::TimeWithZone and causes `version.changeset` to silently return
# {} (the rescue in AuditLogsHelper#audit_version_changes then renders "No
# tracked field changes recorded"). Allow the common AR/AS value types.
Rails.application.config.after_initialize do
  ActiveRecord.yaml_column_permitted_classes |= [
    Symbol,
    Date,
    Time,
    DateTime,
    BigDecimal,
    ActiveSupport::TimeWithZone,
    ActiveSupport::TimeZone,
    ActiveSupport::HashWithIndifferentAccess,
    ActiveSupport::Duration
  ]
end
