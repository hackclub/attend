class ScrubSensitiveIncidentDataFromAuditTrails < ActiveRecord::Migration[8.1]
  # Free-text incident content (all `encrypts`-declared columns) was stored in
  # plaintext inside PaperTrail versions and AuditLog#changed_fields. Going
  # forward these fields are skipped/redacted at write time; this migration
  # removes what was already persisted.
  SCRUBBED_FIELDS = {
    "Incident" => %w[summary details actions_taken],
    "IncidentComment" => %w[body],
    "IncidentReport" => %w[summary details]
  }.freeze

  def up
    SCRUBBED_FIELDS.each do |record_type, fields|
      scrub_versions(record_type, fields)
      scrub_audit_log_changed_fields(record_type, fields)
    end
  end

  def down
    # Irreversible: the scrubbed plaintext is intentionally destroyed.
  end

  private

  def scrub_versions(item_type, fields)
    select_rows(
      "SELECT id, object, object_changes FROM versions WHERE item_type = #{quote(item_type)}"
    ).each do |id, object, object_changes|
      new_object = scrub_yaml(object, fields)
      new_changes = scrub_yaml(object_changes, fields)
      next if new_object.nil? && new_changes.nil?

      sets = [ "object = #{quote(new_object || object)}",
               "object_changes = #{quote(new_changes || object_changes)}" ]
      execute("UPDATE versions SET #{sets.join(', ')} WHERE id = #{quote(id)}")
    end
  end

  # Returns re-serialized YAML with the sensitive keys removed, or nil when
  # nothing needed scrubbing (including unparseable payloads, left untouched).
  def scrub_yaml(yaml, fields)
    return nil if yaml.blank?

    data = YAML.unsafe_load(yaml)
    return nil unless data.is_a?(Hash)
    return nil unless fields.any? { |f| data.key?(f) }

    fields.each { |f| data.delete(f) }
    YAML.dump(data)
  rescue Psych::Exception
    nil
  end

  def scrub_audit_log_changed_fields(record_type, fields)
    fields_array = "ARRAY[#{fields.map { |f| quote(f) }.join(', ')}]"
    execute(<<~SQL)
      UPDATE audit_logs
      SET changed_fields = changed_fields - #{fields_array}
      WHERE record_type = #{quote(record_type)}
        AND changed_fields ?| #{fields_array}
    SQL

    # Older rows may predate the filter_parameters additions, leaving raw form
    # params in metadata->'params'. Scrub the nested model params hash too.
    param_key = record_type.underscore
    execute(<<~SQL)
      UPDATE audit_logs
      SET metadata = jsonb_set(metadata, '{params,#{param_key}}', (metadata->'params'->#{quote(param_key)}) - #{fields_array})
      WHERE record_type = #{quote(record_type)}
        AND (metadata->'params'->#{quote(param_key)}) ?| #{fields_array}
    SQL
  end
end
