# A broadcast (Message, SlackBlast or SeriesBroadcast) that BroadcastScreener
# held back as possible marketing, spam, or off-topic, waiting on a global
# admin. Filed against its event, or for a SeriesBroadcast, its series.
#
# Approving releases it: the broadcast goes out (or back to its schedule).
# Rejecting sends a Message back to draft for its author to fix, or retires a
# SlackBlast. If the author cancels a held message, its review is withdrawn.
class BroadcastReview < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :reviewable, polymorphic: true
  belongs_to :event, optional: true
  belongs_to :event_series, optional: true
  belongs_to :submitted_by_user, class_name: "User", optional: true
  belongs_to :decided_by_user, class_name: "User", optional: true

  enum :status, {
    pending: "pending",
    approved: "approved",
    rejected: "rejected",
    withdrawn: "withdrawn"
  }

  FLAGGED_BY = %w[heuristics model].freeze
  CATEGORY_LABELS = {
    "marketing" => "Marketing",
    "spam" => "Spam",
    "off_topic" => "Not about the event",
    "personal_contact" => "Personal contact details"
  }.freeze

  validates :flagged_by, inclusion: { in: FLAGGED_BY }
  validates :content_digest, presence: true
  validate :filed_against_event_or_series

  scope :recent, -> { order(created_at: :desc) }

  after_create_commit :notify_reviewers

  # How the sender's notice describes each category ("flagged this message
  # as promotional").
  FLAGGED_AS = {
    "marketing" => "promotional",
    "spam" => "spam",
    "off_topic" => "off-topic",
    "personal_contact" => "sharing personal contact details"
  }.freeze

  # What the sender sees while it's held.
  def sender_notice
    flagged_as = categories.map { |c| FLAGGED_AS.fetch(c, c.humanize.downcase) }.to_sentence.presence || "needing a check"
    notice = "Attend flagged this message as #{flagged_as}. A Hack Club HQ staffer will review your message, " \
      "and either approve, or reject it."
    # Slack blasts can't be withdrawn, only messages and series broadcasts.
    reviewable.respond_to?(:cancel!) ? "#{notice} You can withdraw it if you'd like to make an amendment." : notice
  end

  def category_labels
    categories.map { |c| CATEGORY_LABELS.fetch(c, c.humanize) }
  end

  def kind_label
    case reviewable_type
    when "SlackBlast" then "Slack blast"
    when "SeriesBroadcast" then "Series broadcast"
    else "Message"
    end
  end

  # The series whose owners may review it: the event's, or the series a
  # SeriesBroadcast went to.
  def series_id
    event_series_id || event&.event_series_id
  end

  # What it was going to: an event, or every chosen event in a series.
  def target_name
    event&.name || "#{event_series&.name} (series)"
  end

  def approve!(user, note: nil)
    # Held before a BroadcastScreener::BLOCKED rule existed: no approval can
    # send it, so it has to be rejected (or edited by its author).
    blocked = reviewable.blocked_content_reasons
    raise DecisionError, blocked.first if blocked.any?

    decide!(:approved, user, note) do
      reviewable.update_columns(screened_digest: content_digest)
    end
    reviewable.release_after_review!(by: user)
  end

  def reject!(user, note: nil)
    decide!(:rejected, user, note) { reviewable.return_after_rejection! }
  end

  def withdraw!
    update!(status: :withdrawn, decided_at: Time.current) if pending?
  end

  private

  def filed_against_event_or_series
    errors.add(:base, "needs an event or a series") if event_id.blank? && event_series_id.blank?
  end

  # Locks the review so two admins can't both decide it, and refuses if the
  # broadcast moved on meanwhile (cancelled, or edited since it was held).
  def decide!(status, user, note)
    with_lock do
      raise DecisionError, "This review has already been #{self.status}." unless pending?
      raise DecisionError, "This #{kind_label.downcase} is no longer waiting for review." unless reviewable.pending_review?

      update!(status: status, decided_by_user: user, decided_at: Time.current, decision_note: note.presence)
      yield
    end
  end

  def notify_reviewers
    BroadcastReviewMailer.flagged(broadcast_review: self).deliver_later
  end

  class DecisionError < StandardError; end
end
