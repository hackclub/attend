# A reason someone can be on an eligible-only stay's roster, set per stay by
# its organizers: "bought it in the shop", "paying $40 for the night", "other".
class RoomingEligibilityOption < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :rooming_context
  has_many :roster_entries, class_name: "RoomingRosterEntry", dependent: :nullify

  validates :label, presence: true, uniqueness: { scope: :rooming_context_id, case_sensitive: false }
  validates :price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :price_is_a_number

  scope :ordered, -> { order(Arel.sql("position IS NULL, position ASC, created_at ASC")) }

  # Forms take dollars; we store cents so totals never drift.
  def price
    price_cents && price_cents / 100.0
  end

  def price=(value)
    amount = value.blank? ? nil : BigDecimal(value.to_s.delete("$, "), exception: false)
    @price_invalid = value.present? && amount.nil?
    self.price_cents = amount && (amount * 100).round
  end

  def display_label
    return label unless price_cents

    "#{label} (#{ActiveSupport::NumberHelper.number_to_currency(price)})"
  end

  private

  def price_is_a_number
    errors.add(:price, "isn't a number") if @price_invalid
  end
end
