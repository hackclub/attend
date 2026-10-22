# One S0–S3 scale for event incidents and reports to HQ, matching HQ's triage
# chart. Data is remapped in both directions so the migration is reversible.
class StandardiseIncidentLevels < ActiveRecord::Migration[8.1]
  SEVERITY = { "critical" => "s0", "high" => "s1", "medium" => "s2", "low" => "s3" }.freeze
  PRIORITY = { "emergency" => "s0", "elevated" => "s1", "standard" => "s2" }.freeze

  def up
    remap :incidents, :severity, SEVERITY
    remap :incident_reports, :priority, PRIORITY
  end

  def down
    remap :incidents, :severity, SEVERITY.invert
    # s3 had no old equivalent; "standard" is the closest.
    remap :incident_reports, :priority, PRIORITY.invert.merge("s3" => "standard")
  end

  private

  def remap(table, column, mapping)
    mapping.each do |from, to|
      execute <<~SQL.squish
        UPDATE #{table} SET #{column} = #{quote(to)} WHERE #{column} = #{quote(from)}
      SQL
    end
  end
end
