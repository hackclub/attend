class ScanContext < ApplicationRecord
  include TravelCalendarCacheInvalidatable

  self.implicit_order_column = "created_at"

  belongs_to :event
  has_many :scans, dependent: :destroy

  # What a scan here says about where the participant is, with the one-line
  # meaning staff see wherever they choose one. The kind is the source of
  # truth; checks_in and is_travel_pickup are kept in step with it
  # (OLD_FLAGS) for the API and the code that still reads them.
  KIND_DESCRIPTIONS = {
    "venue" => "Arriving at the event venue. Counts as checking in.",
    "lodging" => "Arriving at lodging, or leaving the venue for the night.",
    "pickup" => "Staff collecting participants on their way in, like an airport pickup.",
    "supervised_outing" => "Leaving with staff, like a bus tour.",
    "outing" => "Leaving without staff, like free time or an errand. Use this if unsure.",
    "departure" => "Leaving the event for good, including an airport drop-off.",
    "tracking_only" => "Records the scan without changing where someone is, like lunch or swag."
  }.freeze

  enum :kind, KIND_DESCRIPTIONS.keys.index_with(&:itself), validate: { allow_nil: true }

  # Kinds whose scans place a participant somewhere. Tracking-only scans
  # (lunch, swag) never change where someone is.
  PLACING_KINDS = (kinds.keys - %w[tracking_only]).to_set.freeze

  OLD_FLAGS = Hash.new({ checks_in: false, is_travel_pickup: false }).merge(
    "venue" => { checks_in: true, is_travel_pickup: false },
    "pickup" => { checks_in: false, is_travel_pickup: true }
  ).freeze

  validates :usage_note, length: { maximum: 200 }

  validates :name, presence: true
  validates :checks_in, inclusion: { in: [ true, false ] }
  validates :is_travel_pickup, inclusion: { in: [ true, false ] }
  validate :ends_at_after_starts_at

  default_scope { order(:position, :created_at) }

  before_validation :sync_kind_and_old_flags

  validate :cannot_disable_last_check_in_context, if: :will_unset_checks_in?
  before_destroy :ensure_not_last_check_in_context
  before_destroy :ensure_not_hotel_scan_context

  def kind_label
    (kind || kind_from_old_flags).humanize
  end

  # A kind for points saved before kinds existed, read from the old flags in
  # the same order as the backfill migration.
  def kind_from_old_flags
    return "lodging" if persisted? && event&.hotel_scan_context_id == id
    return "pickup" if is_travel_pickup?
    return "venue" if checks_in?

    "tracking_only"
  end

  private

  # A new kind writes the old flags; a point saved without a kind (the
  # default check-in point, older callers) gets one from its flags. Saves
  # that don't change the kind leave the flags alone.
  def sync_kind_and_old_flags
    if kind.nil?
      self.kind = kind_from_old_flags
    elsif new_record? || will_save_change_to_kind?
      assign_attributes(OLD_FLAGS[kind])
    end
  end

  def travel_calendar_event_ids
    [ event_id, saved_change_to_event_id&.first ]
  end

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
      errors.add(:kind, "must stay Venue: the event needs at least one Venue scan point to check people in")
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
