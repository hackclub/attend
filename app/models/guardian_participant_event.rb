class GuardianParticipantEvent < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :guardian
  belongs_to :participant_event
  has_one :participant, through: :participant_event
  has_one :event, through: :participant_event
  has_many :emergency_contacts, dependent: :destroy
  accepts_nested_attributes_for :emergency_contacts, allow_destroy: true, reject_if: :all_blank

  has_many :consents, dependent: :nullify

  encrypts :invite_token_ciphertext

  enum :status, { pending: "pending", in_progress: "in_progress", completed: "completed" }

  validates :guardian_id, presence: true
  validates :participant_event_id, presence: true, uniqueness: { scope: :guardian_id }

  before_create :set_invited_via_email

  def invite_token
    invite_token_ciphertext
  end

  def generate_invite_token!
    return invite_token if invite_token_ciphertext.present?

    # The invitation mailer and SMS job both call this concurrently on a fresh
    # record. with_lock reloads under a row lock, so the re-check sees a token
    # the other job just committed instead of overwriting it — an overwritten
    # token means the already-delivered link 404s forever.
    with_lock do
      next invite_token if invite_token_ciphertext.present?

      token = SecureRandom.urlsafe_base64(32)
      update!(
        invite_token_ciphertext: token,
        invite_token_digest: Digest::SHA256.hexdigest(token)
      )
      token
    end
  end

  def invite_url
    host = ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "localhost:3000" }
    Rails.application.routes.url_helpers.guardian_portal_url(
      token: invite_token || generate_invite_token!,
      host: host
    )
  end

  INVITE_VALIDITY = 7.days

  def invite_expired?
    return false if accepted_at.present?
    invite_token_sent_at.present? && invite_token_sent_at < INVITE_VALIDITY.ago
  end

  def mark_accepted!
    update!(accepted_at: Time.current, status: :in_progress)
  end

  def completed?
    status == "completed"
  end

  def self.find_by_invite_token!(token)
    digest = Digest::SHA256.hexdigest(token)
    record = find_by!(invite_token_digest: digest)
    raise ActiveRecord::RecordNotFound, "Invite has expired" if record.invite_expired?
    record
  end

  private

  def set_invited_via_email
    self.invited_via_email = guardian.email
  end
end
