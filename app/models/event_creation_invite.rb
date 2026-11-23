# A global admin's invitation for someone to create an event and set it up
# themselves. Creating events is otherwise limited to global admins and to
# series members inside their own series (EventPolicy#create?).
#
# The link goes to one email address and only the account with that address
# can accept it. Accepting ties the invite to that account, which may then
# create exactly one event (in `event_series`, when the invite names one) and
# becomes its event admin.
class EventCreationInvite < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  LINK_VALIDITY = 14.days

  belongs_to :invited_by, class_name: "User", optional: true
  belongs_to :accepted_by, class_name: "User", optional: true
  belongs_to :event_series, optional: true
  belongs_to :event, optional: true

  before_validation :normalize_email
  before_validation :set_expiration, on: :create

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :note, length: { maximum: 1000 }
  validate :email_not_banned, on: :create
  validate :no_open_invite_for_email, on: :create

  # Neither used nor withdrawn.
  scope :open, -> { where(completed_at: nil, revoked_at: nil) }
  # Sent, and still waiting for the person to accept.
  scope :awaiting, -> { open.where(accepted_at: nil).where("event_creation_invites.expires_at > ?", Time.current) }
  scope :for_email, ->(email) { where(email: email.to_s.strip.downcase) }

  # The invites that let this account create an event right now: accepted by
  # it, not yet used, not revoked. An accepted invite no longer expires; the
  # person may be partway through deciding on a name.
  def self.usable_by(user)
    return none unless user

    open.where(accepted_by_id: user.id).where.not(accepted_at: nil)
  end

  def self.find_by_token(token)
    return nil if token.blank?

    find_by(token_digest: digest(token))
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  # pending → started → completed, or expired / revoked along the way.
  def status
    if revoked_at then "revoked"
    elsif completed_at then "completed"
    elsif accepted_at then "started"
    elsif expires_at.past? then "expired"
    else "pending"
    end
  end

  %w[pending started completed expired revoked].each do |name|
    define_method(:"#{name}?") { status == name }
  end

  def usable?
    started?
  end

  # Whether this account can go through the invite's welcome page: it's theirs
  # (addressed to them, or already accepted by them) and still has an event
  # to make.
  def open_to?(user)
    return false unless user && (pending? || started?)

    accepted_by_id ? accepted_by_id == user.id : addressed_to?(user)
  end

  # Only the account the invite was addressed to. A forwarded link doesn't
  # carry the permission with it.
  def addressed_to?(user)
    user.present? && user.email.to_s.strip.downcase == email
  end

  # Issues a fresh link and returns its token, which is stored only as a
  # digest. Any earlier link stops working, so the newest email is always the
  # one that works.
  def issue_token!
    token = SecureRandom.urlsafe_base64(32)
    update!(token_digest: self.class.digest(token), last_sent_at: Time.current)
    token
  end

  def deliver_later
    EventCreationInviteMailer.invite(self).deliver_later
  end

  # Sends the link again with a full validity window.
  def resend!
    update!(expires_at: LINK_VALIDITY.from_now)
    deliver_later
  end

  def accept!(user)
    raise ArgumentError, "invite is not addressed to this account" unless addressed_to?(user)

    with_lock do
      next if started? && accepted_by_id == user.id
      raise ActiveRecord::RecordInvalid, self unless pending?

      update!(accepted_by: user, accepted_at: Time.current)
    end
  end

  def complete!(event)
    update!(event: event, completed_at: Time.current)
  end

  def revoke!
    update!(revoked_at: Time.current) unless revoked_at
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase
  end

  def set_expiration
    self.expires_at ||= LINK_VALIDITY.from_now
  end

  def email_not_banned
    errors.add(:email, "is on the conduct ban list") if email.present? && Ban.banned?(email)
  end

  # One live invite per address, so there's never a question of which link or
  # which series an email was about. Resend or revoke the existing one.
  def no_open_invite_for_email
    return if email.blank?

    existing = self.class.open.for_email(email)
    live = existing.awaiting.or(existing.where.not(accepted_at: nil))
    errors.add(:email, "already has an open invite. Resend or revoke that one instead.") if live.exists?
  end
end
