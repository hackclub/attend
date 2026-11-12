# A broadcast (Message or SlackBlast) that BroadcastScreener held back as
# possible marketing, spam, or off-topic, waiting on a global admin.
#
# Approving releases it: the broadcast goes out (or back to its schedule).
# Rejecting sends a Message back to draft for its author to fix, or retires a
# SlackBlast. If the author cancels a held message, its review is withdrawn.
class BroadcastReview < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :reviewable, polymorphic: true
  belongs_to :event
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
    "off_topic" => "Not about the event"
  }.freeze

  validates :flagged_by, inclusion: { in: FLAGGED_BY }
  validates :content_digest, presence: true

  scope :recent, -> { order(created_at: :desc) }

  after_create_commit :notify_reviewers

  def category_labels
    categories.map { |c| CATEGORY_LABELS.fetch(c, c.humanize) }
  end

  def kind_label
    reviewable_type == "SlackBlast" ? "Slack blast" : "Message"
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
