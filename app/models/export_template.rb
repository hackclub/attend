class ExportTemplate < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :event
  belongs_to :created_by, class_name: "User"

  validates :name, presence: true, uniqueness: { scope: :event_id, case_sensitive: false }
  validates :row_mode, inclusion: { in: Exports::FieldRegistry::ROW_MODES }
  validates :columns, presence: true
  validate :columns_exist_in_registry
  validate :filters_are_valid

  def filter_objects
    Array(filters).filter_map { |f| Exports::Filter.build(f.to_h.stringify_keys) }
  end

  private

  def columns_exist_in_registry
    unknown = Array(columns).map(&:to_s) - Exports::FieldRegistry::FIELDS.keys
    errors.add(:columns, "contains unknown fields: #{unknown.join(', ')}") if unknown.any?
  end

  def filters_are_valid
    Array(filters).each do |raw|
      filter = Exports::Filter.build(raw.to_h.stringify_keys)
      unless filter&.valid?
        errors.add(:filters, "contains an invalid filter")
        break
      end
    end
  end
end
