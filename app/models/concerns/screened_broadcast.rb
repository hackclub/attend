# Holds broadcasts that look like marketing, spam or off-topic for a global
# admin to review before they go out (see BroadcastScreener, BroadcastReview).
#
# Included by Message and SlackBlast, which provide:
#   screening_subject / screening_text  what the screener reads
#   release_after_review!(by:)          send it once an admin approves
#   return_after_rejection!             what a rejection does to it
# and a `pending_review` status.
#
# `screened_digest` remembers the content last cleared (by the screener, a
# global admin sending it, or an approval), so it isn't screened again until
# someone edits it.
module ScreenedBroadcast
  extend ActiveSupport::Concern

  included do
    has_many :broadcast_reviews, as: :reviewable, dependent: :destroy
  end

  def content_digest
    Digest::SHA256.hexdigest([ screening_subject.to_s, screening_text.to_s ].join("\u0000"))
  end

  def screening_cleared?
    screened_digest.present? && screened_digest == content_digest
  end

  # Screens unless already cleared. Returns nil when the broadcast may go out
  # (recording that, so it isn't screened again), or the screener's flagged
  # Result. Global admins are the reviewers, so what they send isn't screened.
  # Makes a network call: run it outside any row lock.
  def screen_for_review(sender:)
    return if screening_cleared?

    result = sender&.global_admin? ? nil : BroadcastScreener.call(event: event, subject: screening_subject, text: screening_text)
    return result if result&.flagged?

    update_columns(screened_digest: content_digest)
    nil
  end

  def hold_for_review!(result, sender:)
    update!(status: :pending_review)
    broadcast_reviews.create!(
      event: event,
      submitted_by_user: sender,
      flagged_by: result.flagged_by,
      categories: result.categories,
      reason: result.reason,
      content_digest: content_digest
    )
  end

  def pending_broadcast_review
    broadcast_reviews.pending.order(:created_at).last
  end

  def latest_broadcast_review
    broadcast_reviews.order(:created_at).last
  end
end
