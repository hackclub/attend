# One S0–S3 scale for event incidents and reports to HQ, matching HQ's triage
# chart. Live rows and their PaperTrail versions are remapped in both
# directions so the migration is reversible and old versions still reify.
class StandardiseIncidentLevels < ActiveRecord::Migration[8.1]
  SEVERITY = { "critical" => "s0", "high" => "s1", "medium" => "s2", "low" => "s3" }.freeze
  PRIORITY = { "emergency" => "s0", "elevated" => "s1", "standard" => "s2" }.freeze

  def up
    remap :incidents, :severity, SEVERITY
    remap :incident_reports, :priority, PRIORITY
    remap_versions "Incident", "severity", SEVERITY
    remap_versions "IncidentReport", "priority", PRIORITY
  end

  def down
    remap :incidents, :severity, SEVERITY.invert
    # s3 had no old equivalent; "standard" is the closest.
    remap :incident_reports, :priority, PRIORITY.invert.merge("s3" => "standard")
    remap_versions "Incident", "severity", SEVERITY.invert
    remap_versions "IncidentReport", "priority", PRIORITY.invert.merge("s3" => "standard")
  end

  private

  def remap(table, column, mapping)
    mapping.each do |from, to|
      execute <<~SQL.squish
        UPDATE #{table} SET #{column} = #{quote(to)} WHERE #{column} = #{quote(from)}
      SQL
    end
  end

  # PaperTrail stores `object` as a YAML hash ("severity: critical") and
  # `object_changes` as a YAML hash of [before, after] lists under the
  # attribute key. Both are rewritten textually, scoped to the attribute's
  # own line or list so no other attribute's value is touched.
  def remap_versions(item_type, attribute, mapping)
    rows = select_rows("SELECT id, object, object_changes FROM versions WHERE item_type = #{quote(item_type)}")
    rows.each do |id, object, object_changes|
      new_object = object && object.gsub(/^#{attribute}: (\S+)$/) { "#{attribute}: #{mapping.fetch($1, $1)}" }
      new_changes = object_changes && object_changes.gsub(/^#{attribute}:\n((?:- \S*\n?)+)/) do
        "#{attribute}:\n" + $1.gsub(/^- (\S*)/) { "- #{mapping.fetch($1, $1)}" }
      end
      next if new_object == object && new_changes == object_changes

      # Not squished: the quoted YAML carries the newlines that make it YAML.
      execute "UPDATE versions SET object = #{quote(new_object)}, object_changes = #{quote(new_changes)} WHERE id = #{quote(id)}"
    end
  end
end
