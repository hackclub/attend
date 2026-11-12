# Tells reviewers that BroadcastScreener held a broadcast back. Goes to
# BROADCAST_REVIEW_EMAIL (or credentials broadcast_review.email) when set,
# otherwise to every global admin.
class BroadcastReviewMailer < ApplicationMailer
  def flagged(broadcast_review:)
    @review = broadcast_review
    @event = broadcast_review.event
    @sender = broadcast_review.submitted_by_user
    @excerpt = broadcast_review.reviewable.screening_text.to_s.truncate(600)
    @review_url = Rails.application.routes.url_helpers.admin_broadcast_review_url(
      @review, host: default_host, protocol: default_protocol
    )

    to = self.class.reviewer_emails
    return if to.empty?

    mail(to: to, subject: "Review a held #{@review.kind_label.downcase} for #{@event.name}")
  end

  def self.reviewer_emails
    configured = ENV["BROADCAST_REVIEW_EMAIL"].presence ||
      Rails.application.credentials.dig(:broadcast_review, :email).presence
    return Array(configured) if configured

    User.where(global_role: "global_admin").where.not(email: [ nil, "" ]).pluck(:email)
  end

  private

  def default_host
    ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "localhost:3000" }
  end

  def default_protocol
    Rails.env.local? ? "http" : "https"
  end
end
