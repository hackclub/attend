class Participant < ApplicationRecord
  include WalletPassUpdatable

  has_paper_trail

  self.implicit_order_column = "created_at"

  # `phone` is encrypted deterministically because it is queried by exact value
  # (e.g. Ticket lookup, inbound Twilio/Signal message routing).
  # `date_of_birth` is NOT encrypted here because admin filters use SQL range
  # comparisons against it (BETWEEN, <, >), which Rails encryption breaks.
  # Tracked separately — see CodeQL alerts referenced in the PR.
  encrypts :phone, deterministic: true

  belongs_to :user, optional: true
  has_many :participant_events, dependent: :destroy
  has_many :events, through: :participant_events
  has_many :sibling_memberships, dependent: :destroy
  has_many :sibling_groups, through: :sibling_memberships

  has_one_attached :headshot, dependent: :purge_later
  # Deliberately separate from `headshot`, which is the official photo used for
  # event operations (badges, rosters) — changing the public photo must never
  # touch it.
  has_one_attached :public_profile_photo, dependent: :purge_later

  enum :engagement_preference, {
    very_social: "very_social",
    social_with_downtime: "social_with_downtime",
    balanced: "balanced",
    mostly_focused: "mostly_focused",
    very_focused: "very_focused"
  }

  # Public profiles are strictly opt-in. Slugs live under the fixed /p/ prefix,
  # so they can't collide with app routes.
  PUBLIC_PROFILE_SLUG_FORMAT = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  validates :legal_first_name, presence: true
  validates :legal_last_name, presence: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :date_of_birth, presence: true, on: :onboarding
  validates :headshot, presence: true, on: :onboarding
  validates :phone, phone: { possible: true, allow_blank: true }
  validate :headshot_content_type
  validates :public_profile_slug, presence: true, if: :public_profile_enabled?
  validates :public_profile_slug,
    uniqueness: true,
    length: { in: 3..40 },
    format: { with: PUBLIC_PROFILE_SLUG_FORMAT, message: "can only contain lowercase letters, numbers, and hyphens" },
    allow_blank: true
  validates :public_profile_bio, length: { maximum: 500 }
  validates :public_profile_location, length: { maximum: 100 }
  validates :public_profile_website,
    format: { with: %r{\Ahttps?://[^\s]+\z}, message: "must start with http:// or https://" },
    allow_blank: true
  validates :public_profile_mastodon,
    format: { with: %r{\Ahttps://[^\s]+\z}, message: "must be a Mastodon profile URL or @user@instance handle" },
    allow_blank: true
  validate :public_profile_photo_content_type

  # Accept pasted profile URLs and strip them down to bare handles.
  normalizes :public_profile_github, with: ->(value) {
    value.strip.sub(%r{\Ahttps?://(www\.)?github\.com/}i, "").delete_prefix("@").delete_suffix("/").presence
  }
  normalizes :public_profile_twitter, with: ->(value) {
    value.strip.sub(%r{\Ahttps?://(www\.)?(twitter|x)\.com/}i, "").delete_prefix("@").delete_suffix("/").presence
  }
  normalizes :public_profile_linkedin, with: ->(value) {
    value.strip.sub(%r{\Ahttps?://(www\.)?linkedin\.com/in/}i, "").delete_prefix("@").delete_suffix("/").presence
  }
  normalizes :public_profile_bluesky, with: ->(value) {
    value.strip.sub(%r{\Ahttps?://(www\.)?bsky\.app/profile/}i, "").delete_prefix("@").delete_suffix("/").presence
  }
  # Store Mastodon as a full profile URL: accept `@user@instance.tld` or a URL.
  # The https:// format validation above rejects anything else (e.g. javascript:).
  normalizes :public_profile_mastodon, with: ->(value) {
    value = value.strip
    if (match = value.match(/\A@?([^@\s\/]+)@([^@\s\/]+)\z/))
      "https://#{match[2]}/@#{match[1]}"
    else
      value.presence
    end
  }
  # Bare domains get https://; anything already carrying a scheme (including
  # javascript:) is left alone so the https?:// format validation can reject it.
  normalizes :public_profile_website, with: ->(value) {
    value = value.strip
    value = "https://#{value}" if value.present? && !value.match?(/\A[a-z][a-z0-9+.-]*:/i)
    value.presence
  }

  before_validation :normalize_phone
  before_validation :normalize_public_profile_slug
  before_validation :generate_public_profile_slug, if: -> { public_profile_enabled? && public_profile_slug.blank? }
  after_update_commit :touch_participant_events

  def full_name
    "#{legal_first_name} #{legal_last_name}"
  end

  def display_name
    preferred_name.presence || full_name
  end

  def age_on(date)
    return nil unless date_of_birth

    age = date.year - date_of_birth.year
    age -= 1 if date < date_of_birth + age.years
    age
  end

  def minor_on?(date)
    age = age_on(date)
    return false if age.nil?

    age < 18
  end

  def siblings
    Participant
      .joins(:sibling_memberships)
      .where(sibling_memberships: { sibling_group_id: sibling_group_ids })
      .where.not(id: id)
      .distinct
  end

  def sibling_of?(other_participant)
    return false if sibling_group_ids.empty?

    (sibling_group_ids & other_participant.sibling_group_ids).any?
  end

  def pending_invitations
    Invitation.pending.for_email(email).where.not(event_id: event_ids)
  end

  # Events that may appear on the public profile: fully registered, actually
  # checked in on site, and the event has already ended. Upcoming events are
  # never shown publicly — a profile must not reveal where a (mostly minor)
  # participant will be.
  def public_profile_eligible_participant_events
    participant_events
      .complete
      .joins(:event)
      .where(events: { ends_at: ..Time.current })
      .where(id: Scan.for_check_in.select(:participant_event_id))
      .order("events.starts_at DESC")
  end

  # The eligible set minus events the participant chose to hide.
  def public_profile_participant_events
    public_profile_eligible_participant_events.where(hidden_from_public_profile: false)
  end

  # Staffing comes from the linked user's event role assignments rather than a
  # participant_event. The same privacy rule applies — only events that have
  # already ended may appear. Staff don't check in through scans, so the role
  # assignment itself qualifies.
  def public_profile_eligible_staff_role_assignments
    return EventRoleAssignment.none if user_id.blank?

    EventRoleAssignment
      .where(user_id: user_id)
      .joins(:event)
      .where(events: { ends_at: ..Time.current })
  end

  # Distinct staffed events minus the ones hidden from the profile. A user can
  # hold several roles on one event, so visibility is per event: it shows
  # unless every assignment for that event is hidden.
  def public_profile_staff_events
    Event
      .where(id: public_profile_eligible_staff_role_assignments
        .where(hidden_from_public_profile: false)
        .select(:event_id))
      .order(starts_at: :desc)
  end

  # Verified through Hack Club Auth identity verification.
  def hca_verified?
    user&.hca_verified? || false
  end

  # The photo shown on the public profile: the participant's uploaded photo,
  # falling back to the official event headshot.
  def public_profile_display_photo
    return public_profile_photo if public_profile_photo.attached?

    headshot if headshot.attached?
  end

  private

  def participant_events_to_update
    participant_events.to_a
  end

  def touch_participant_events
    participant_events.touch_all
  end

  def normalize_public_profile_slug
    return if public_profile_slug.blank?

    self.public_profile_slug = public_profile_slug.strip.downcase
  end

  def generate_public_profile_slug
    base = display_name.to_s.downcase
      .gsub(/[^a-z0-9\s-]/, "")
      .strip
      .gsub(/[\s-]+/, "-")
      .first(30)
      .delete_suffix("-")
    base = "participant" if base.length < 3

    candidate = base
    suffix = 1
    while Participant.where(public_profile_slug: candidate).where.not(id: id).exists?
      suffix += 1
      candidate = "#{base}-#{suffix}"
    end

    self.public_profile_slug = candidate
  end

  def normalize_phone
    return if phone.blank?

    if phone.start_with?("+")
      parsed = Phonelib.parse(phone)
      self.phone = parsed.e164 if parsed.valid?
    else
      parsed = Phonelib.parse(phone, nil)
      self.phone = parsed.e164 if parsed.valid?
    end
  end

  def headshot_content_type
    return unless headshot.attached?

    unless headshot.content_type.in?(%w[image/jpeg image/png image/webp])
      errors.add(:headshot, "must be a JPEG, PNG, or WebP image")
    end

    if headshot.blob.byte_size > 10.megabytes
      errors.add(:headshot, "must be less than 10MB")
    end
  end

  def public_profile_photo_content_type
    return unless public_profile_photo.attached?

    unless public_profile_photo.content_type.in?(%w[image/jpeg image/png image/webp])
      errors.add(:public_profile_photo, "must be a JPEG, PNG, or WebP image")
    end

    if public_profile_photo.blob.byte_size > 10.megabytes
      errors.add(:public_profile_photo, "must be less than 10MB")
    end
  end
end
