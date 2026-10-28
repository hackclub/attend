# One stay at an event: the main stay, a pre-event night, a post-event night.
# Each context has its own rooming plan, rooms and assignments, so a person can
# hold one room per context. Every event has at most one main context, created
# on demand by Event#main_rooming_context.
class RoomingContext < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  MAIN_NAME = "Main stay".freeze

  belongs_to :event
  has_one :rooming_plan, dependent: :destroy
  has_many :rooms, dependent: :destroy
  has_many :room_assignments

  enum :kind, {
    main: "main",
    pre_event: "pre_event",
    post_event: "post_event",
    custom: "custom"
  }

  # everyone: every registered participant with accommodation is in the pool
  # unless marked exempt (the original single-stay behaviour).
  # eligible_only: only people put on this stay's list are in the pool.
  enum :enrollment, {
    everyone: "everyone",
    eligible_only: "eligible_only"
  }

  validates :name, presence: true, uniqueness: { scope: :event_id }
  validates :kind, uniqueness: { scope: :event_id }, if: :main?
  validate :ends_on_after_starts_on

  scope :ordered, -> { order(Arel.sql("position IS NULL, position ASC, created_at ASC")) }

  # Everyone this stay is rooming, exempt or not. Eligible-only stays have no
  # list to draw from yet, so their pool is empty.
  def participant_events
    return event.participant_events.none if eligible_only?

    event.participant_events
      .where(status: %w[complete in_progress])
      .joins(:accommodation)
  end

  # The people who still need a bed in this stay: in the pool and not exempt.
  def assignable_participant_events
    participant_events.where(accommodations: { rooming_exempt: false })
  end

  def exempt_participant_events
    participant_events.where(accommodations: { rooming_exempt: true })
  end

  private

  def ends_on_after_starts_on
    return unless starts_on && ends_on && ends_on < starts_on

    errors.add(:ends_on, "must be on or after the start date")
  end
end
