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

  # In the order they happen: before, during, after, then anything else.
  scope :ordered, -> { in_order_of(:kind, KIND_LABELS.keys).order(:starts_on, :created_at) }

  def kind_label
    KIND_LABELS.fetch(kind)
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

  private

  def ends_on_after_starts_on
    return unless starts_on && ends_on && ends_on < starts_on

    errors.add(:ends_on, "must be on or after the start date")
  end
end
