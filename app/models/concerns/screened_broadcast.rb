# Holds broadcasts that look like marketing, spam or off-topic for a global
# admin to review before they go out (see BroadcastScreener, BroadcastReview).
#
# Included by Message, SlackBlast and SeriesBroadcast, which provide:
#   screening_subject / screening_text  what the screener reads
#   release_after_review!(by:)          send it once an admin approves
#   return_after_rejection!             what a rejection does to it
# and a `pending_review` status. One that doesn't belong to a single event
# (SeriesBroadcast) also overrides #screening_event and
# #broadcast_review_owner.
#
# `screened_digest` remembers the content last cleared (by the screener, a
# global admin sending it, or an approval), so it isn't screened again until
# someone edits it.
module ScreenedBroadcast
  extend ActiveSupport::Concern

  included do
    has_many :broadcast_reviews, as: :reviewable, dependent: :destroy

    validate :blocked_content, if: :check_blocked_content?
  end

  # BroadcastScreener::BLOCKED content can't be saved, so it can't be sent,
  # even by a global admin or after an approval. Raw HTML is checked as well
  # as the screened text, which is where a link's address ends up.
  def blocked_content
    blocked_content_reasons.each { |reason| errors.add(:base, reason) }
  end

  def blocked_content_reasons
    BroadcastScreener.blocked_reasons(screening_subject, screening_text, *blocked_content_sources)
      .map { |reason| "#{model_name.human} #{reason}" }
  end

  def content_digest
    Digest::SHA256.hexdigest([ screening_subject.to_s, screening_text.to_s ].join("\u0000"))
  end

  def screening_cleared?
    screened_digest.present? && screened_digest == content_digest
  end

  # Screens unless already cleared. Returns nil when the broadcast may go out
  # (recording that, so it isn't screened again), or the screener's flagged
  # Result. Global admins are the reviewers, so what they send isn't screened,
  # unless trust_sender is false: a send nobody is making right now (a
  # scheduled send, a series broadcast's copy) is credited to its author but
  # mustn't ride on their exemption, since someone else may have edited it.
  # Makes a network call: run it outside any row lock.
  def screen_for_review(sender:, trust_sender: true)
    return if screening_cleared?

    result = trust_sender && sender&.global_admin? ? nil : BroadcastScreener.call(event: screening_event, subject: screening_subject, text: screening_text)
    return result if result&.flagged?

    update_columns(screened_digest: content_digest)
    nil
  end

  def hold_for_review!(result, sender:)
    update!(status: :pending_review)
    broadcast_reviews.create!(
      **broadcast_review_owner,
      submitted_by_user: sender,
      flagged_by: result.flagged_by,
      categories: result.categories,
      reason: result.reason,
      content_digest: content_digest
    )
  end

  # What the screener judges the broadcast against: its event's name, dates
  # and venue.
  def screening_event
    event
  end

  # Where a held review is filed, which decides who may review it (see
  # BroadcastReviewPolicy).
  def broadcast_review_owner
    { event: event }
  end

  def pending_broadcast_review
    broadcast_reviews.pending.order(:created_at).last
  end

  def latest_broadcast_review
    broadcast_reviews.order(:created_at).last
  end
end
