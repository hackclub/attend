class AddUniqueIndexToPasskitDevicesIdentifier < ActiveRecord::Migration[8.0]
  def up
    # Dedupe first: concurrent wallet registrations could insert the same
    # identifier twice (ATTEND-7R), so the index would fail to build if any
    # duplicates already exist. Keep the newest device per identifier (it has
    # the freshest push_token), repoint registrations at it, drop the rest.
    duplicate_ids = select_rows(<<~SQL)
      SELECT identifier, (array_agg(id ORDER BY updated_at DESC, id DESC))[1] AS keeper_id
      FROM passkit_devices
      WHERE identifier IS NOT NULL
      GROUP BY identifier
      HAVING COUNT(*) > 1
    SQL

    duplicate_ids.each do |identifier, keeper_id|
      loser_ids = select_values(
        "SELECT id FROM passkit_devices WHERE identifier = #{quote(identifier)} AND id != #{quote(keeper_id)}"
      )
      next if loser_ids.empty?

      quoted_losers = loser_ids.map { |id| quote(id) }.join(", ")

      # Drop registrations that would become duplicates of one the keeper
      # already has, then move the remainder over.
      execute(<<~SQL)
        DELETE FROM passkit_registrations lr
        USING passkit_registrations kr
        WHERE lr.passkit_device_id IN (#{quoted_losers})
          AND kr.passkit_device_id = #{quote(keeper_id)}
          AND kr.passkit_pass_id = lr.passkit_pass_id
      SQL

      execute(<<~SQL)
        UPDATE passkit_registrations
        SET passkit_device_id = #{quote(keeper_id)}
        WHERE passkit_device_id IN (#{quoted_losers})
      SQL

      execute("DELETE FROM passkit_devices WHERE id IN (#{quoted_losers})")
    end

    add_index :passkit_devices, :identifier, unique: true
  end

  def down
    remove_index :passkit_devices, :identifier
  end
end
