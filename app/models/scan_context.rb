class ScanContext < ApplicationRecord
  include TravelCalendarCacheInvalidatable

  self.implicit_order_column = "created_at"

  belongs_to :event
  has_many :scans, dependent: :destroy

  # What a scan here says about where the participant is, with the one-line
  # meaning staff see wherever they choose one. The kind is the source of
  # truth: setting it writes checks_in and is_travel_pickup, which the API
  # and the rest of the app still read.
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
  PLACING_KINDS = (kinds.keys - %w[tracking_only]).freeze

  # Points whose scans place people, counting a point saved without a kind
  # (by older code mid-deploy) by its flags, as kind_from_old_flags does.
  scope :placing, -> {
    where(kind: PLACING_KINDS).or(where(kind: nil).where(<<~SQL.squish))
      checks_in OR is_travel_pickup OR EXISTS (
        SELECT 1 FROM events
        WHERE events.id = scan_contexts.event_id AND events.hotel_scan_context_id = scan_contexts.id
      )
    SQL
  }

  # Browsers count a line break as one character but submit two.
  normalizes :usage_note, with: ->(note) { note.gsub("\r\n", "\n").strip.presence }
  validates :usage_note, length: { maximum: 200 }

  validates :name, presence: true
  validates :checks_in, inclusion: { in: [ true, false ] }
  validates :is_travel_pickup, inclusion: { in: [ true, false ] }
  validate :ends_at_after_starts_at

  # Every context list (scanner, admin list, filters) uses one order:
  # scheduled contexts by start time, unscheduled ones after, then by manual
  # position.
  default_scope { order(arel_table[:starts_at].asc.nulls_last, :position, :created_at) }

  before_validation :sync_kind_and_old_flags

  validate :cannot_disable_last_check_in_context, if: :will_unset_checks_in?
  before_destroy :ensure_not_last_check_in_context
  before_destroy :ensure_not_hotel_scan_context

  # The kind, or for a point saved without one, the kind its flags give it.
  def effective_kind
    kind || kind_from_old_flags
  end

  def kind_label
    effective_kind.humanize
  end

  private

  # In the same order as the backfill migration: the flags decide first, so a
  # point that checks people in is always a Venue.
  def kind_from_old_flags
    return "venue" if checks_in?
    return "pickup" if is_travel_pickup?
    return "lodging" if persisted? && event&.hotel_scan_context_id == id

    "tracking_only"
  end

  # Setting a kind writes the old flags; a point saved without a kind (the
  # default check-in point, older callers) gets one from its flags, and so
  # does one whose flags were written without its kind (older code
  # mid-deploy, a console update). Other saves leave the flags alone.
  def sync_kind_and_old_flags
    if kind.nil?
      self.kind = kind_from_old_flags
    elsif will_save_change_to_kind?
      assign_attributes(checks_in: venue?, is_travel_pickup: pickup?)
    elsif !old_flags_match_kind?
      self.kind = kind_from_old_flags
    end
  end

  # A Venue may also be a travel pickup: points that were both keep marking
  # travel as collected until staff change their kind.
  def old_flags_match_kind?
    checks_in? == venue? && (is_travel_pickup? == pickup? || venue?)
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
      errors.add(:base, "Cannot delete the last Venue scan point: the event needs one to check people in")
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
