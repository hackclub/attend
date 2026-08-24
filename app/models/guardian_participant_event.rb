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

  # Handing this link to someone counts as sending it: an unstamped invite is
  # treated as dead by #invite_expired?, so admins copying a link out of the
  # participant page would otherwise paste a URL that 404s on arrival. Only
  # stamp a link that is actually dead -- this renders inside the admin
  # participant page, and refreshing a live invite on every page load would
  # write (and record a PaperTrail version) for every guardian shown.
  def invite_url
    host = ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "localhost:3000" }
    token = generate_invite_token!
    update!(invite_token_sent_at: Time.current) if invite_expired?

    Rails.application.routes.url_helpers.guardian_portal_url(
      token: token,
      host: host
    )
  end

  INVITE_VALIDITY = 7.days

  # Bump at most hourly. The window is measured in days, so stamping every
  # request would buy no useful precision and add a write to each page load.
  INVITE_USE_TOUCH_INTERVAL = 1.hour

  # The window slides off whichever happened last: the invite being sent, or the
  # guardian actually using it. Measuring from the send alone would cut off
  # anyone still working through the portal seven days after the first email.
  # A record with neither timestamp has had its invite revoked (an admin changed
  # the guardian's email) or never had one delivered, so its token is dead
  # rather than eternal -- that unstamped-means-forever gap was the original bug.
  def invite_expired?
    last_active_at = [ invite_token_sent_at, invite_last_used_at ].compact.max
    return true if last_active_at.nil?

    last_active_at < INVITE_VALIDITY.ago
  end

  # Called on every authenticated portal request. Callers reach this only after
  # find_by_invite_token! has already rejected expired tokens, so this extends a
  # live window and can never resurrect a dead one.
  def touch_invite_use!
    return if invite_last_used_at.present? && invite_last_used_at > INVITE_USE_TOUCH_INTERVAL.ago

    update_column(:invite_last_used_at, Time.current)
  end

  def mark_accepted!
    update!(accepted_at: Time.current, status: :in_progress)
  end

  def completed?
    status == "completed"
  end

  def self.find_by_invite_token!(token)
    digest = Digest::SHA256.hexdigest(token)
    # The guardian portal reads guardian, participant_event, participant, and
    # event on every request. eager_load fetches the whole chain in a single
    # joined query instead of five sequential lookups; every association is
    # singular, so the LIMIT 1 stays on the one joined query.
    record = eager_load(:guardian, participant_event: [ :participant, :event ])
      .find_by!(invite_token_digest: digest)
    raise ActiveRecord::RecordNotFound, "Invite has expired" if record.invite_expired?
    record
  end

  private

  def set_invited_via_email
    self.invited_via_email = guardian.email
  end
end
