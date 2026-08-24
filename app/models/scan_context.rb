class ScanContext < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :event
  has_many :scans, dependent: :destroy

  validates :name, presence: true
  validates :checks_in, inclusion: { in: [ true, false ] }
  validates :is_travel_pickup, inclusion: { in: [ true, false ] }
  validate :ends_at_after_starts_at

  default_scope { order(:position, :created_at) }

  validate :cannot_disable_last_check_in_context, if: :will_unset_checks_in?
  before_destroy :ensure_not_last_check_in_context
  before_destroy :ensure_not_hotel_scan_context

  private

  def ends_at_after_starts_at
    return if starts_at.blank? || ends_at.blank?

    if ends_at <= starts_at
      errors.add(:ends_at, "must be after the start time")
    end
  end

  def will_unset_checks_in?
    checks_in_changed?(from: true, to: false)
  end

  def cannot_disable_last_check_in_context
    if last_check_in_context_for_event?
      errors.add(:checks_in, "Event must have at least one check-in context")
    end
  end

  def ensure_not_last_check_in_context
    return if destroyed_by_association || event.destroyed? || event.marked_for_destruction?

    if checks_in? && last_check_in_context_for_event?
      errors.add(:base, "Cannot delete the last check-in context for this event")
      throw :abort
    end
  end

  def ensure_not_hotel_scan_context
    Event.where(hotel_scan_context_id: id).update_all(hotel_scan_context_id: nil)
  end

  def last_check_in_context_for_event?
    event.scan_contexts.unscoped.where(event_id: event_id, checks_in: true).where.not(id: id).none?
  end
end
