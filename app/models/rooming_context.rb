# One stay at an event: during the event (a hotel, say), the night before,
# the night after. Each has its own rooming plan, rooms and assignments, so a
# person can hold one room per stay. None of them is required: locals don't
# need a bed, and an event where everyone sleeps at the venue may have no
# stays at all. An event has at most one during-the-event stay; its kind is
# "main" for historical reasons.
class RoomingContext < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  MAIN_NAME = "During the event".freeze

  KIND_LABELS = {
    "pre_event" => "Before the event",
    "main" => "During the event",
    "post_event" => "After the event",
    "custom" => "Other"
  }.freeze

  belongs_to :event
  # The lodging scan point people are scanned at on arrival for this stay.
  # Its arrival numbers count only people with a room in the stay.
  belongs_to :scan_context, optional: true
  has_one :rooming_plan, dependent: :destroy
  has_many :rooms, dependent: :destroy
  has_many :room_assignments
  has_many :eligibility_options, -> { ordered }, class_name: "RoomingEligibilityOption", dependent: :destroy, inverse_of: :rooming_context
  has_many :roster_entries, class_name: "RoomingRosterEntry", dependent: :destroy

  accepts_nested_attributes_for :eligibility_options, allow_destroy: true, reject_if: ->(attrs) { attrs["label"].blank? && attrs["id"].blank? }

  enum :kind, {
    main: "main",
    pre_event: "pre_event",
    post_event: "post_event",
    custom: "custom"
  }

  # everyone: every registered participant with accommodation is in the pool
  # unless marked exempt (they live locally, say).
  # eligible_only: only people put on this stay's list are in the pool.
  enum :enrollment, {
    everyone: "everyone",
    eligible_only: "eligible_only"
  }

  validates :name, presence: true, uniqueness: { scope: :event_id }
  validates :kind, uniqueness: { scope: :event_id, message: "already has a during-the-event stay" }, if: :main?
  validate :ends_on_after_starts_on

  after_create :create_check_in_point!
  after_update :rename_check_in_point, if: :saved_change_to_name?
  before_destroy :release_check_in_point

  # In the order they happen: before, during, after, then anything else.
  scope :ordered, -> { in_order_of(:kind, KIND_LABELS.keys).order(:starts_on, :created_at) }

  def kind_label
    KIND_LABELS.fetch(kind)
  end

  # The same order as the ordered scope, for sorting stays already loaded.
  def sort_key
    [ KIND_LABELS.keys.index(kind), starts_on ? 0 : 1, starts_on.to_s, created_at.to_f ]
  end

  # Everyone this stay is rooming, exempt or not. An eligible-only stay draws
  # from its roster. Either way, rooming needs the accommodation form (gender,
  # roommate preferences), so someone who hasn't filled it in isn't in the
  # pool yet; the roster page shows who's waiting on it.
  def participant_events
    scope = event.participant_events
      .where(status: %w[complete in_progress])
      .joins(:accommodation)
    eligible_only? ? scope.where(id: roster_entries.select(:participant_event_id)) : scope
  end

  # The people who still need a bed in this stay. Exemption is an everyone
  # stay's opt-out; being on an eligible-only stay's roster is already an
  # opt-in.
  def assignable_participant_events
    return participant_events if eligible_only?

    participant_events.where(accommodations: { rooming_exempt: false })
  end

  def exempt_participant_events
    return event.participant_events.none if eligible_only?

    participant_events.where(accommodations: { rooming_exempt: true })
  end

  # Gives the stay a lodging scan point, unless it has one. A stay during the
  # event adopts the event's hotel scan point when there's a free one, and
  # becomes it when there isn't, so the existing hotel features keep working.
  def create_check_in_point!
    return scan_context if scan_context

    point = adoptable_hotel_scan_context || event.scan_contexts.create!(
      name: check_in_point_name,
      kind: "lodging",
      usage_note: "Arrivals for #{name}. Counts only people with a room in this stay."
    )
    # Columns, not update!: a failed update! inside after_create is swallowed
    # by save and surfaces as a blank 422. The point is built for this event,
    # so the validations update! would run hold already.
    update_column(:scan_context_id, point.id)
    self.scan_context = point
    event.update_column(:hotel_scan_context_id, point.id) if main? && event.hotel_scan_context_id.nil?
    point
  end

  # Everyone with a room in this stay: who the check-in point expects.
  def expected_participant_event_ids
    room_assignments.select(:participant_event_id)
  end

  def expected_count
    room_assignments.count
  end

  # Expected people with at least one scan at the stay's check-in point.
  def arrived_count
    return 0 unless scan_context

    room_assignments.where(participant_event_id: scan_context.scans.select(:participant_event_id)).count
  end

  private

  def check_in_point_name(stay_name = name)
    "#{stay_name} arrivals"
  end

  def adoptable_hotel_scan_context
    return unless main?

    hotel = event.hotel_scan_context
    hotel if hotel && !RoomingContext.where(scan_context: hotel).where.not(id: id).exists?
  end

  # Only renames a point that still has the name it was given, so one an
  # organizer has renamed keeps their name.
  def rename_check_in_point
    return unless scan_context&.name == check_in_point_name(name_before_last_save)

    scan_context.update!(name: check_in_point_name)
  end

  # A point nobody was scanned at goes with the stay. One with scans stays
  # for the record, as does the event's hotel point, which may predate
  # stays; the foreign key drops the link either way.
  def release_check_in_point
    point = scan_context
    return if point.nil? || point.scans.exists? || event.hotel_scan_context_id == point.id

    update_column(:scan_context_id, nil)
    point.destroy!
  end

  def ends_on_after_starts_on
    return unless starts_on && ends_on && ends_on < starts_on

    errors.add(:ends_on, "must be on or after the start date")
  end
end
