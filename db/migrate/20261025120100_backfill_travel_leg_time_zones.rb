require "yaml"

# Gives every existing leg time the zone admin pages already show it in: the
# airport's zone from config/airport_timezones.yml, or UTC when the airport
# isn't listed. For an unlisted airport, UTC is also the zone the time was read
# in when it was saved, so it shows the time the traveller typed. Pinning the
# zones now keeps those legs put if the airport list grows later.
# Only rows with a time and no zone yet are touched, so re-running it is safe.
class BackfillTravelLegTimeZones < ActiveRecord::Migration[8.1]
  def up
    path = Rails.root.join("config/airport_timezones.yml")
    zones = File.exist?(path) ? YAML.load_file(path).transform_keys { |k| k.to_s.upcase } : {}

    %w[departure arrival].each do |endpoint|
      zones.each do |code, zone|
        execute <<~SQL.squish
          UPDATE travel_legs SET #{endpoint}_time_zone = #{quote(zone)}
          WHERE #{endpoint}_time IS NOT NULL AND #{endpoint}_time_zone IS NULL
            AND UPPER(TRIM(#{endpoint}_airport)) = #{quote(code)}
        SQL
      end

      execute <<~SQL.squish
        UPDATE travel_legs SET #{endpoint}_time_zone = 'Etc/UTC'
        WHERE #{endpoint}_time IS NOT NULL AND #{endpoint}_time_zone IS NULL
      SQL
    end
  end

  # The zones can't be told apart from ones picked after the backfill, so
  # rolling this back keeps them; rolling back the column migration drops them.
  def down; end

  private

  def quote(value) = connection.quote(value)
end
