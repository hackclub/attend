class MoveHotelScanContextToEvents < ActiveRecord::Migration[8.1]
  def change
    add_reference :events, :hotel_scan_context, type: :uuid, null: true, foreign_key: { to_table: :scan_contexts }

    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE events
          SET hotel_scan_context_id = rooming_plans.hotel_scan_context_id
          FROM rooming_plans
          WHERE rooming_plans.event_id = events.id
            AND rooming_plans.hotel_scan_context_id IS NOT NULL
        SQL
      end
    end

    remove_reference :rooming_plans, :hotel_scan_context, type: :uuid, foreign_key: { to_table: :scan_contexts }
  end
end
