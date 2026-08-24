class Event < ApplicationRecord
  include WalletPassUpdatable
  include RasterizesSvgLogo
  include DecodableImageAttachment

  has_paper_trail

  self.implicit_order_column = "created_at"

  store_accessor :config,
    :freedom_waivers_enabled,
    :travel_enabled,
    :visa_options_enabled,
    :visa_application_url,
    :accommodation_enabled,
    :roommate_preferences_enabled,
    :guardian_invites_locked,
    :nfc_badges_enabled,
    :nfc_badge_write_on_checkin_enabled,
    :groups_enabled,
    :airtable_api_key,
    :airtable_base_id,
    :vote_event_id,
    :vote_event_slug,
    :vote_event_admin_url,
    :vote_event_gallery_url,
    :vote_event_linked_at

  after_initialize :set_default_config, if: :new_record?

  # Airtable ids/keys are copy-pasted; stray whitespace yields baffling
  # 403/404s from the API. The api key and base id live in the config store,
  # which `normalizes` doesn't cover, so their writers strip too.
  normalizes :airtable_sync_source_id, :airtable_sync_table_id, with: ->(v) { v.strip.presence }

  def airtable_api_key=(value)
    super(value.is_a?(String) ? value.strip.presence : value)
  end

  def airtable_base_id=(value)
    super(value.is_a?(String) ? value.strip.presence : value)
  end

  has_one_attached :logo
  has_one_attached :banner

  ALLOWED_LOGO_CONTENT_TYPES = %w[image/jpeg image/png image/gif image/webp image/svg+xml].freeze
  MAX_LOGO_BYTE_SIZE = 5.megabytes

  # Google Wallet hero images only support PNG and JPEG
  ALLOWED_BANNER_CONTENT_TYPES = %w[image/jpeg image/png].freeze
  MAX_BANNER_BYTE_SIZE = 5.megabytes

  validate :acceptable_logo
  validate :acceptable_banner

  belongs_to :event_series, optional: true

  has_many :participant_events, dependent: :destroy
  has_many :participants, through: :participant_events
  has_many :event_role_assignments, dependent: :destroy
  has_many :staff_users, through: :event_role_assignments, source: :user
  has_many :incidents, dependent: :destroy
  has_many :notes, dependent: :destroy
  has_many :audit_logs, dependent: :delete_all
  has_many :invitations, dependent: :destroy
  has_many :event_api_tokens, dependent: :destroy
  has_many :slack_blasts, dependent: :destroy
  has_many :messages, dependent: :destroy
  has_many :scan_contexts, dependent: :destroy
  has_many :rooms, dependent: :destroy
  has_many :groups, dependent: :destroy
  has_many :export_templates, dependent: :destroy
  has_many :custom_documents, dependent: :destroy
  has_many :import_batches, dependent: :delete_all
  has_many :email_logs, dependent: :nullify
  has_many :incident_reports, dependent: :nullify
  has_many :tickets, dependent: :nullify
  has_one :rooming_plan, dependent: :destroy
  belongs_to :hotel_scan_context, class_name: "ScanContext", optional: true
  belongs_to :airtable_config_updated_by, class_name: "User", optional: true

  # events.hotel_scan_context_id references scan_contexts, which are destroyed
  # before the event row is deleted — clear it first or the FK rejects the delete
  before_destroy prepend: true do
    update_column(:hotel_scan_context_id, nil) if hotel_scan_context_id?
  end

  after_create :create_default_scan_context

  RESERVED_SLUGS = %w[
    new events users settings search audit_logs blazer console jobs
    api admin dashboard login logout sign_in sign_out series
  ].freeze

  validates :name, presence: true

  # Support email is the from/reply-to on every participant- and guardian-facing
  # email, so it has to be an address we actually control. Required from setup
  # onwards; older events created before this rule keep passing validation until
  # someone edits the field (hence allow_blank on the format check).
  SUPPORT_EMAIL_DOMAINS = %w[hackclub.com events.hackclub.com].freeze
  SUPPORT_EMAIL_FORMAT = /\A[^@\s]+@(?:#{SUPPORT_EMAIL_DOMAINS.map { |d| Regexp.escape(d) }.join("|")})\z/i

  normalizes :support_email, with: ->(v) { v.strip.downcase.presence }

  validates :support_email, presence: true, on: :create
  validates :support_email, presence: true, on: :update, if: :support_email_changed?
  validates :support_email,
            format: {
              with: SUPPORT_EMAIL_FORMAT,
              message: "must be a #{SUPPORT_EMAIL_DOMAINS.map { |d| "@#{d}" }.join(" or ")} address"
            },
            allow_blank: true

  validates :slug, presence: true,
                   uniqueness: true,
                   format: { with: /\A[a-z0-9-]+\z/, message: "must be lowercase with no spaces (dashes allowed)" },
                   exclusion: { in: RESERVED_SLUGS, message: "is reserved and cannot be used" }

  before_validation :generate_slug_from_name, if: -> { slug.blank? && name.present? }
  before_validation :assign_default_docuseal_host, on: :create, if: -> { docuseal_host.blank? }
  before_validation :interpret_naive_schedule_times_in_event_timezone

  # datetime-local form inputs submit zone-less strings like "2026-07-12T09:30".
  # Rails would cast those in the app default zone (UTC); we capture the raw
  # string here and re-parse it in the event's timezone once validation runs
  # (by which point a timezone submitted in the same form has been assigned).
  NAIVE_DATETIME_PATTERN = /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?\z/
  SCHEDULE_TIME_ATTRIBUTES = %i[starts_at ends_at registration_open_at registration_close_at].freeze

  SCHEDULE_TIME_ATTRIBUTES.each do |attr|
    define_method(:"#{attr}=") do |value|
      if value.is_a?(String) && value.match?(NAIVE_DATETIME_PATTERN)
        (@naive_schedule_times ||= {})[attr] = value
      end
      super(value)
    end
  end
  after_save :geocode_location, if: :should_geocode?
  after_save :send_pending_guardian_invites, if: :guardian_invites_just_unlocked?

  attr_accessor :api_key

  def generate_api_key!
    key = "attn_#{SecureRandom.hex(32)}"
    update!(api_key_digest: Digest::SHA256.hexdigest(key))
    @api_key = key
    key
  end

  def self.find_by_api_key(key)
    return nil if key.blank?

    digest = Digest::SHA256.hexdigest(key)
    find_by(api_key_digest: digest)
  end

  def api_key_set?
    api_key_digest.present?
  end

  def vote_event_linked?
    vote_event_id.present?
  end

  # Persists the linkage to a vote.hackclub.com event from an API response body.
  def link_vote_event!(body)
    update!(
      vote_event_id: body["id"],
      vote_event_slug: body["slug"],
      vote_event_admin_url: body["adminUrl"],
      vote_event_gallery_url: body["galleryUrl"],
      vote_event_linked_at: Time.current.iso8601
    )
  end

  def to_param
    slug
  end

  scope :drafts, -> { where(setup_completed_at: nil) }
  # Events whose staff may still work the shared support inbox: anytime before
  # the event through 7 days after it ends.
  scope :within_support_window, -> { where(ends_at: 7.days.ago..) }

  def setup_complete?
    setup_completed_at.present?
  end

  def active?
    return false if starts_at.nil? || ends_at.nil?

    Time.current.between?(starts_at, ends_at)
  end

  def completed?
    ends_at.present? && ends_at.to_date < Date.current
  end

  def registration_open?
    return false if registration_open_at.nil? || registration_close_at.nil?

    Time.current.between?(registration_open_at, registration_close_at)
  end

  def event_time_zone
    ActiveSupport::TimeZone[timezone.to_s.presence || "UTC"] || Time.zone
  end

  # IANA identifier (e.g. "America/Los_Angeles") for API clients — `timezone`
  # holds a Rails zone name like "Pacific Time (US & Canada)", which JS's
  # Intl APIs don't understand.
  def timezone_identifier
    ActiveSupport::TimeZone[timezone.to_s]&.tzinfo&.name
  end

  # Value for datetime-local form fields: the stored time expressed in the
  # event's timezone, so admins always see and edit event-local times.
  def schedule_time_field_value(attr)
    public_send(attr)&.in_time_zone(event_time_zone)&.strftime("%Y-%m-%dT%H:%M")
  end

  def formatted_date_range
    return nil if starts_at.nil? || ends_at.nil?

    tz = event_time_zone
    start_date = starts_at.in_time_zone(tz).to_date
    end_date = ends_at.in_time_zone(tz).to_date

    if start_date == end_date
      start_date.strftime("%B %-d, %Y")
    elsif start_date.year == end_date.year && start_date.month == end_date.month
      "#{start_date.strftime('%B %-d')} - #{end_date.strftime('%-d, %Y')}"
    elsif start_date.year == end_date.year
      "#{start_date.strftime('%B %-d')} - #{end_date.strftime('%B %-d, %Y')}"
    else
      "#{start_date.strftime('%B %-d, %Y')} - #{end_date.strftime('%B %-d, %Y')}"
    end
  end

  def freedom_waivers_enabled?
    ActiveModel::Type::Boolean.new.cast(freedom_waivers_enabled)
  end

  def travel_enabled?
    # Events created before this toggle existed have no config key — treat as enabled
    return true if travel_enabled.nil?

    ActiveModel::Type::Boolean.new.cast(travel_enabled)
  end

  def visa_options_enabled?
    ActiveModel::Type::Boolean.new.cast(visa_options_enabled)
  end

  def accommodation_enabled?
    ActiveModel::Type::Boolean.new.cast(accommodation_enabled)
  end

  def guardian_invites_locked?
    ActiveModel::Type::Boolean.new.cast(guardian_invites_locked)
  end

  def roommate_preferences_enabled?
    ActiveModel::Type::Boolean.new.cast(roommate_preferences_enabled)
  end

  def nfc_badges_enabled?
    ActiveModel::Type::Boolean.new.cast(nfc_badges_enabled)
  end

  def nfc_badge_write_on_checkin_enabled?
    ActiveModel::Type::Boolean.new.cast(nfc_badge_write_on_checkin_enabled)
  end

  def groups_enabled?
    ActiveModel::Type::Boolean.new.cast(groups_enabled)
  end

  def airtable_sync_configured?
    airtable_api_key.present? &&
      airtable_base_id.present? &&
      airtable_sync_source_id.present? &&
      airtable_sync_table_id.present?
  end

  # The SQL counterpart of #airtable_sync_configured?, for the scheduled sync.
  #
  # Written as raw SQL on purpose. `where.not(airtable_sync_source_id: [nil, ""])`
  # looks equivalent but isn't: `normalizes` above rewrites query values too, so
  # the "" collapses to nil and the predicate degrades to `IS NOT NULL` — which
  # matches every event that has an empty string stored (any event whose
  # integrations form was ever saved blank). Those events then reach
  # Airtable::Client, which raises on the blank key, once per event per run.
  scope :with_airtable_sync_configured, -> {
    where("NULLIF(BTRIM(events.airtable_sync_source_id), '') IS NOT NULL")
      .where("NULLIF(BTRIM(events.airtable_sync_table_id), '') IS NOT NULL")
      .where("NULLIF(BTRIM(events.config ->> 'airtable_api_key'), '') IS NOT NULL")
      .where("NULLIF(BTRIM(events.config ->> 'airtable_base_id'), '') IS NOT NULL")
  }

  scope :with_airtable_sync_active, -> {
    with_airtable_sync_configured.where(airtable_sync_paused_at: nil)
  }

  # AirtableJobs::SyncAllJob runs every 5 minutes and only advances
  # airtable_synced_at on success, so anything older than this means the sync
  # has been failing — the job rescues per event, so nothing else surfaces it.
  AIRTABLE_SYNC_STALE_AFTER = 30.minutes

  def airtable_sync_stale?
    return false unless airtable_sync_configured?
    # A paused sync isn't drifting silently — it has its own explicit state, an
    # error message, and an email already sent to whoever can fix it.
    return false if airtable_sync_paused?

    airtable_synced_at.nil? || airtable_synced_at < AIRTABLE_SYNC_STALE_AFTER.ago
  end

  def airtable_sync_paused?
    airtable_sync_paused_at.present?
  end

  # One failure stops the schedule. Retrying broken credentials every 5 minutes
  # never fixes them; it just buries the real signal under thousands of
  # identical errors. A human re-saving the config (or hitting "Sync Now") is
  # the only thing that resumes it.
  def pause_airtable_sync!(error_message)
    update_columns(
      airtable_sync_paused_at: Time.current,
      airtable_sync_error: error_message,
      airtable_sync_error_at: Time.current
    )
  end

  def resume_airtable_sync!
    update_columns(
      airtable_sync_paused_at: nil,
      airtable_sync_error: nil,
      airtable_sync_error_at: nil
    )
  end

  # Whoever last saved the Airtable credentials — the only person who can
  # actually fix them, so the one we email when the sync pauses. Events
  # configured before airtable_config_updated_by_id existed still have an audit
  # trail (the integrations form writes an `update_integrations` log), so fall
  # back to that rather than leaving them with nobody to notify.
  def airtable_config_last_saved_by
    airtable_config_updated_by || last_integrations_saver
  end

  def venue_coordinates
    return nil if location_latitude.blank? || location_longitude.blank?
    { lat: location_latitude.to_f, lon: location_longitude.to_f }
  end

  def logo_displayable?
    return true if logo.attached? && logo.content_type == "image/svg+xml"

    displayable_image?(logo)
  end

  # Memoized because list views reach this once or twice per row via
  # ParticipantEvent#applicable_custom_documents, and all rows share this
  # instance when :event is preloaded.
  def active_custom_documents
    @active_custom_documents ||= if custom_documents.loaded?
      custom_documents.select { |doc| doc.archived_at.nil? }.sort_by(&:created_at)
    else
      custom_documents.active.order(:created_at).to_a
    end
  end

  # Branding fallback: an event without its own logo/banner inherits its
  # series' assets. Used in the admin UI and wallet pass generation (banner).
  def effective_logo
    return logo if logo.attached?

    series_logo = event_series&.logo
    series_logo if series_logo&.attached?
  end

  def effective_banner
    return banner if banner.attached?

    series_banner = event_series&.banner
    series_banner if series_banner&.attached?
  end

  # Outbound-mail contact: the event's own support email, else its series'
  # contact email, else the global default.
  def effective_support_email
    support_email.presence || event_series&.contact_email.presence || "team@hackclub.com"
  end

  private

  def interpret_naive_schedule_times_in_event_timezone
    return if @naive_schedule_times.blank?

    tz = event_time_zone
    @naive_schedule_times.each do |attr, raw|
      parsed = begin
        tz.parse(raw)
      rescue ArgumentError
        nil
      end
      self[attr] = parsed if parsed
    end
    @naive_schedule_times = nil
  end

  def assign_default_docuseal_host
    self.docuseal_host = Docuseal::HostConfig.default_host
  end

  def acceptable_logo
    return unless attachment_changes["logo"].present?

    unless ALLOWED_LOGO_CONTENT_TYPES.include?(logo.content_type)
      errors.add(:logo, "must be a JPEG, PNG, GIF, WebP, or SVG image")
    end

    if logo.byte_size && logo.byte_size > MAX_LOGO_BYTE_SIZE
      errors.add(:logo, "must be smaller than 5MB")
    end

    validate_decodable_image(:logo)
  end

  def acceptable_banner
    return unless attachment_changes["banner"].present?

    unless ALLOWED_BANNER_CONTENT_TYPES.include?(banner.content_type)
      errors.add(:banner, "must be a PNG or JPEG image")
    end

    if banner.byte_size && banner.byte_size > MAX_BANNER_BYTE_SIZE
      errors.add(:banner, "must be smaller than 5MB")
    end

    validate_decodable_image(:banner)
  end

  def participant_events_to_update
    participant_events.to_a
  end

  def generate_slug_from_name
    self.slug = name.downcase.gsub(/\s+/, "-").gsub(/[^a-z0-9-]/, "")
  end

  def last_integrations_saver
    audit_logs.where(action: :update_integrations)
              .where.not(actor_user_id: nil)
              .order(created_at: :desc)
              .first&.actor
  end

  def set_default_config
    self.freedom_waivers_enabled = true if freedom_waivers_enabled.nil?
    self.travel_enabled = true if travel_enabled.nil?
    self.visa_options_enabled = true if visa_options_enabled.nil?
    self.accommodation_enabled = true if accommodation_enabled.nil?
    self.roommate_preferences_enabled = true if roommate_preferences_enabled.nil?
  end

  def should_geocode?
    return false if location_latitude.present? && !location_address_changed?

    saved_change_to_venue_name? || saved_change_to_location_address? ||
      saved_change_to_location_city? || saved_change_to_location_country?
  end

  def geocode_location
    address = geocode_address_string
    return if address.blank?

    result = GeocoderService.geocode(address)
    return unless result

    update_columns(
      location_latitude: result[:latitude],
      location_longitude: result[:longitude]
    )
  end

  def geocode_address_string
    if venue_name.present? || location_address.present?
      [ venue_name, location_address, location_city, location_country ].compact.join(", ")
    else
      [ location_city, location_country ].compact.join(", ")
    end
  end

  def guardian_invites_just_unlocked?
    return false unless saved_change_to_config?

    old_config = config_before_last_save || {}
    was_locked = ActiveModel::Type::Boolean.new.cast(old_config["guardian_invites_locked"])
    now_unlocked = !guardian_invites_locked?

    was_locked && now_unlocked
  end

  def send_pending_guardian_invites
    SendPendingGuardianInvitesJob.perform_later(id)
    # Custom documents added while locked deferred reopening completed
    # participants until now.
    ReopenParticipantsForCustomDocumentsJob.perform_later(id)
  end

  def create_default_scan_context
    scan_contexts.create!(
      name: "Event check-in",
      checks_in: true,
      is_airport: false,
      position: 0
    )
  end
end
