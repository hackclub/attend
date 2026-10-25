class Invitation < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :event

  LINK_VALIDITY = 30.days

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :token, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validate :no_pending_invitation_exists, on: :create
  validate :email_not_banned, on: :create

  before_validation :normalize_email, on: :create
  before_validation :generate_token, on: :create
  before_validation :set_expiration, on: :create

  # Still waiting on the participant. A held invitation counts however old it
  # is: nobody has a link that could have expired, and its validity window
  # only starts when it is finally sent (see #mark_sent!).
  scope :pending, -> { where(accepted_at: nil).where("invitations.sent_at IS NULL OR invitations.expires_at > ?", Time.current) }
  # Recorded but never emailed — the participant doesn't know about the event
  # yet. Released in bulk by SendHeldOnboardingInvitesJob.
  scope :held, -> { where(sent_at: nil, accepted_at: nil) }
  scope :sent, -> { where.not(sent_at: nil) }
  scope :for_email, ->(email) { where("LOWER(email) = ?", email.downcase) }

  # The one entry point for inviting someone to onboard, whichever surface
  # asked (admin form, API, CSV import). Records the invitation and emails it,
  # unless the event is holding onboarding invitations or the caller asked
  # for a silent add — then it sits as `held` until the event releases them.
  #
  # Reuses the pending invitation for the address when there is one, so
  # inviting the same person twice never issues a second token.
  def self.issue!(event:, email:, participant: nil, name: nil, group_ids: nil, send: true)
    address = (participant&.email.presence || email).to_s.strip.downcase

    invitation = pending.find_or_create_by!(email: address, event: event) do |inv|
      inv.name = name.presence
    end
    invitation.update!(name: name) if name.present? && invitation.name.blank?
    invitation.assign_group_ids!(group_ids) if group_ids.is_a?(Array)

    invitation.deliver_later(participant: participant) if send

    invitation
  end

  # Enqueues the invitation email, unless the event is holding onboarding
  # invitations — then it stays `held` for SendHeldOnboardingInvitesJob.
  #
  # Callers that issue an invitation inside a transaction should pass
  # `send: false` to .issue! and call this once the transaction has committed:
  # the job is enqueued immediately, not on commit, and the mailer
  # find-or-creates the invitation row, so a rolled-back issue would still be
  # recreated and emailed by the job.
  def deliver_later(participant: nil)
    return if event.onboarding_invites_held?

    ParticipantMailer.invitation(email: email, name: name, event: event, participant: participant).deliver_later
  end

  def assign_group_ids!(ids)
    valid_ids = event.groups.where(id: ids).pluck(:id)
    update!(group_ids: valid_ids) if valid_ids.any?
  end

  def expired?
    expires_at < Time.current
  end

  def accepted?
    accepted_at.present?
  end

  def pending?
    !accepted? && (held? || !expired?)
  end

  def sent?
    sent_at.present?
  end

  def held?
    !sent? && !accepted?
  end

  def accept!
    update!(accepted_at: Time.current)
  end

  # Stamped by the mailer as the email goes out. The link is good for
  # LINK_VALIDITY from its first send — not from when the invitation was
  # recorded, which for a held one may have been weeks earlier. Resends keep
  # the original window: same token, same expiry.
  def mark_sent!
    attrs = { sent_at: Time.current }
    attrs[:expires_at] = LINK_VALIDITY.from_now unless sent?
    update!(attrs)
  end

  private

  def normalize_email
    self.email = email&.strip&.downcase
  end

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def set_expiration
    self.expires_at ||= LINK_VALIDITY.from_now
  end

  def no_pending_invitation_exists
    return if email.blank? || event_id.blank?

    existing = Invitation.pending.where(event_id: event_id).for_email(email).exists?
    errors.add(:email, "already has a pending invitation for this event") if existing
  end

  def email_not_banned
    errors.add(:email, "is banned from events") if Ban.banned?(email)
  end
end
