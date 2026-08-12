class AddHotelScanContextToRoomingPlans < ActiveRecord::Migration[8.1]
  def change
    add_reference :rooming_plans, :hotel_scan_context, type: :uuid, null: true, foreign_key: { to_table: :scan_contexts }
  end
end
