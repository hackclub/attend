class User < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail ignore: [
    :oidc_claims, :remember_created_at,
    :sign_in_count, :current_sign_in_at, :last_sign_in_at,
    :current_sign_in_ip, :last_sign_in_ip
  ]

  devise :rememberable, :trackable, :omniauthable, omniauth_providers: [ :hack_club ]

  enum :global_role, { no_role: "none", global_admin: "global_admin", read_only: "read_only" }, default: :no_role

  # `oidc_claims` holds PII straight from Hack Club Auth (phone number,
  # birthdate, home address). Encrypting the whole jsonb blob works because the
  # Active Record encryption envelope is itself JSON, so it round-trips through
  # a jsonb column untouched — no custom serializer needed. `phone_number` is
  # the copy `backfill_contact_from_claims!` makes of the same phone, so it gets
  # the same treatment. Neither is queried by value, hence non-deterministic.
  encrypts :oidc_claims
  encrypts :phone_number

  has_one_attached :avatar

  attr_accessor :previous_email_at_sign_in

  ALLOWED_AVATAR_CONTENT_TYPES = %w[image/jpeg image/pjpeg image/png image/gif image/webp].freeze

  validate :acceptable_avatar

  has_many :event_role_assignments, dependent: :destroy
  has_many :assigned_events, through: :event_role_assignments, source: :event
  has_many :series_role_assignments, dependent: :destroy
  has_many :event_series, through: :series_role_assignments
  has_one :participant
  has_one :guardian
  has_many :reported_incidents, class_name: "Incident", foreign_key: "reported_by_user_id"
  has_many :authored_notes, class_name: "Note", foreign_key: "author_user_id"
  has_many :mobile_tokens, dependent: :destroy
  has_many :push_tokens, dependent: :destroy

  validates :email, presence: true, uniqueness: true

  def global_admin?
    global_role == "global_admin"
  end

  def role_for_event(event)
    event_role_assignments.find_by(event: event)&.role
  end

  def can_access_event?(event)
    global_admin? || event_role_assignments.exists?(event: event) || series_member_for_event?(event)
  end

  # Series members act as event admins on every event in their series.
  def series_member_for_event?(event)
    event.event_series_id.present? &&
      series_role_assignments.exists?(event_series_id: event.event_series_id)
  end

  def series_member_for?(series)
    series_role_assignments.exists?(event_series: series)
  end

  def series_owner_for?(series)
    global_admin? || series_role_assignments.exists?(event_series: series, role: :owner)
  end

  def self.from_omniauth(auth)
    Rails.logger.info "[OIDC] Auth UID: #{auth.uid}"
    if Rails.env.development?
      Rails.logger.debug "[OIDC] Auth info: #{auth.info.to_h}"
      Rails.logger.debug "[OIDC] Auth extra.raw_info: #{auth.extra&.raw_info}"
    end

    # Devise downcases and strips the stored email (case_insensitive_keys /
    # strip_whitespace_keys), so the lookup must use the same normalization
    # or a mixed-case address from HCA misses the existing row.
    email = auth.info.email.to_s.strip.downcase.presence

    user = find_by(hack_club_account_id: auth.uid)
    user ||= find_by(email: email) if email

    display_name = auth.info.name.presence ||
                   [ auth.info.first_name, auth.info.last_name ].compact.join(" ").presence ||
                   email&.split("@")&.first

    oidc_claims = extract_oidc_claims(auth).deep_stringify_keys
    if Rails.env.development?
      Rails.logger.debug "[OIDC] Extracted claims: #{oidc_claims}"
    else
      Rails.logger.info "[OIDC] Extracted claim keys: #{oidc_claims.keys}"
    end

    if user
      attrs = {
        hack_club_account_id: auth.uid,
        name: display_name || user.name,
        oidc_claims: oidc_claims
      }
      if email && user.claim_email!(email)
        attrs[:email] = email
      end
      previous_email = user.email
      success = user.update(attrs)
      Rails.logger.info "[OIDC] Update success: #{success}, errors: #{user.errors.full_messages}" unless success
      if success && user.saved_change_to_email?
        user.previous_email_at_sign_in = previous_email
      end
    else
      begin
        user = create!(
          hack_club_account_id: auth.uid,
          email: email,
          name: display_name,
          oidc_claims: oidc_claims
        )
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        # Duplicate concurrent callbacks for a brand-new user both miss the
        # find_by above and both insert; the loser lands here. The winning
        # row was written by the same sign-in, so just use it.
        user = find_by(hack_club_account_id: auth.uid) || (email && find_by(email: email))
        raise e unless user
      end
    end

    user.reload
    user.sync_slack_id_to_participant
    user.sync_email_to_participant
    user.backfill_contact_from_claims!
    user
  end

  # A row created by an admin adding someone by email (staff, series member,
  # or global role) before that person has ever signed in. It exists only to
  # hold role assignments until the person's first sign-in links it up.
  def placeholder_account?
    hack_club_account_id.blank? && sign_in_count.zero?
  end

  # Whether this account may take `new_email` at sign-in. The email can
  # already belong to another User row: admins grant access by email, which
  # creates a placeholder account holding the role assignments. Someone who
  # already had an account under an older email resolves to it by
  # hack_club_account_id at sign-in, stranding the placeholder — and the
  # placeholder's row makes the email update fail uniqueness, silently
  # pinning the stale address AND the whole claims refresh. Absorb the
  # placeholder so its access follows the person onto their real account.
  def claim_email!(new_email)
    other = User.where.not(id: id).find_by(email: new_email)
    return true if other.nil?

    unless other.placeholder_account?
      Rails.logger.warn "[OIDC] Not updating email for user #{id}: address already belongs to active user #{other.id}"
      return false
    end

    absorb_placeholder!(other)
    true
  rescue => e
    Rails.logger.error "[OIDC] Failed to absorb placeholder user #{other&.id} into #{id}: #{e.class} - #{e.message}"
    Sentry.capture_exception(e) if defined?(Sentry)
    false
  end

  GLOBAL_ROLE_RANK = { "no_role" => 0, "read_only" => 1, "global_admin" => 2 }.freeze

  def absorb_placeholder!(placeholder)
    raise ArgumentError, "refusing to absorb a non-placeholder account" unless placeholder.placeholder_account?

    # requires_new so a failure rolls the merge back even when an outer
    # transaction is open (claim_email! rescues and continues sign-in).
    transaction(requires_new: true) do
      placeholder.event_role_assignments.each do |assignment|
        if EventRoleAssignment.exists?(user_id: id, event_id: assignment.event_id, role: assignment.role)
          assignment.destroy!
        else
          assignment.update!(user: self)
        end
      end

      placeholder.series_role_assignments.each do |assignment|
        if SeriesRoleAssignment.exists?(user_id: id, event_series_id: assignment.event_series_id)
          assignment.destroy!
        else
          assignment.update!(user: self)
        end
      end

      if GLOBAL_ROLE_RANK.fetch(placeholder.global_role, 0) > GLOBAL_ROLE_RANK.fetch(global_role, 0)
        self.global_role = placeholder.global_role
        # Skip validations: sign-in must not be blocked by unrelated
        # pre-existing invalid data on this account.
        save!(validate: false)
      end

      placeholder.reload.destroy!
    end
  end

  def sync_slack_id_to_participant
    slack_id = oidc_claims&.dig("slack_id")
    return if slack_id.blank?
    return unless participant.present?

    return if participant.slack_user_id == slack_id

    # Skip validations: this is a system sync, and pre-existing invalid data on
    # the participant (e.g. a legacy phone number) must not block sign-in.
    participant.slack_user_id = slack_id
    participant.save!(validate: false)
  end

  # A Hack Club Auth email change lands on the User row at sign-in; the linked
  # participant must follow, or every mailer and export keeps using the old
  # address indefinitely.
  def sync_email_to_participant
    return if email.blank?
    return unless participant.present?
    return if participant.email == email

    # Skip validations: this is a system sync, and pre-existing invalid data on
    # the participant (e.g. a legacy phone number) must not block sign-in.
    participant.email = email
    participant.save!(validate: false)
  end

  # Seed the editable profile fields from Hack Club OAuth, without clobbering a
  # value the user has set manually.
  def backfill_contact_from_claims!
    updates = {}
    updates[:slack_user_id] = oidc_claims["slack_id"] if slack_user_id.blank? && oidc_claims["slack_id"].present?
    updates[:phone_number] = oidc_claims["phone_number"] if phone_number.blank? && oidc_claims["phone_number"].present?
    return if updates.empty?

    # `update_columns` would bypass the encrypting type and write the phone
    # number as plaintext. Validations are skipped instead, so pre-existing
    # invalid data (e.g. a stale avatar) can't block sign-in.
    assign_attributes(updates)
    save(validate: false)
  end

  def self.extract_oidc_claims(auth)
    raw = auth.extra&.raw_info&.to_h&.with_indifferent_access || {}

    # Handle both OIDC format and HCA API format
    if raw["identity"]
      # HCA API format
      identity = raw["identity"].with_indifferent_access
      primary_address = identity["addresses"]&.find { |a| a["primary"] } || identity["addresses"]&.first
      {
        given_name: identity["first_name"] || raw["given_name"] || auth.info.first_name,
        family_name: identity["last_name"] || raw["family_name"] || auth.info.last_name,
        legal_first_name: identity["legal_first_name"],
        legal_last_name: identity["legal_last_name"],
        preferred_name: identity["first_name"] || raw["nickname"] || raw["given_name"],
        email: identity["primary_email"] || raw["email"] || auth.info.email,
        phone_number: raw["phone"] || raw["phone_number"] || identity["phone"] || identity["phone_number"] || auth.info.phone,
        birthdate: identity["birthday"] || raw["birthdate"],
        address: primary_address&.slice("line_1", "line_2", "city", "state", "postal_code", "country") || oidc_address(raw["address"]),
        slack_id: identity["slack_id"],
        verification_status: identity["verification_status"],
        ysws_eligible: identity["ysws_eligible"]
      }.compact
    else
      # OIDC format
      {
        given_name: raw["given_name"] || auth.info.first_name,
        family_name: raw["family_name"] || auth.info.last_name,
        preferred_name: raw["nickname"] || raw["given_name"],
        email: raw["email"] || auth.info.email,
        phone_number: raw["phone"] || raw["phone_number"] || auth.info.phone,
        birthdate: raw["birthdate"],
        address: oidc_address(raw["address"]),
        slack_id: raw["slack_id"],
        verification_status: raw["verification_status"],
        ysws_eligible: raw["ysws_eligible"]
      }.compact
    end
  end

  def self.oidc_address(address)
    return nil unless address.is_a?(Hash)

    address.slice("street_address", "locality", "region", "postal_code", "country").presence
  end

  # Identity-verified through Hack Club Auth (same signal the admin UI shows).
  def hca_verified?
    oidc_claims["verification_status"] == "verified"
  end

  def admin?
    global_admin? ||
      event_role_assignments.exists?(role: %w[event_admin ops safeguarding_lead]) ||
      series_role_assignments.exists?
  end

  def safeguarding_lead_for?(event)
    global_admin? || event_role_assignments.exists?(event: event, role: :safeguarding_lead)
  end

  def event_admin_for?(event)
    global_admin? ||
      event_role_assignments.exists?(event: event, role: :event_admin) ||
      series_member_for_event?(event)
  end

  def ops_for?(event)
    global_admin? ||
      event_role_assignments.exists?(event: event, role: [ :event_admin, :ops ]) ||
      series_member_for_event?(event)
  end

  # Events where this user can work support tickets (event_admin or ops,
  # or any event in a series they belong to).
  def support_staff_event_ids
    @support_staff_event_ids ||= (
      event_role_assignments.where(role: %w[event_admin ops]).pluck(:event_id) +
        series_event_ids
    ).uniq
  end

  # Access to the pending (not-yet-linked) support queue: global admins always,
  # event staff only while one of their events is within its support window.
  def support_inbox_triage_access?
    global_admin? ||
      event_role_assignments.where(role: %w[event_admin ops])
                            .joins(:event).merge(Event.within_support_window)
                            .exists? ||
      Event.within_support_window.where(id: series_event_ids).exists?
  end

  def series_event_ids
    @series_event_ids ||= Event.where(event_series_id: series_role_assignments.select(:event_series_id)).pluck(:id)
  end

  # Effective contact details: the manually-set override if present, otherwise
  # the value synced from Hack Club OAuth.
  def slack_id
    slack_user_id.presence || oidc_claims&.dig("slack_id")
  end

  def phone
    phone_number.presence || oidc_claims&.dig("phone_number")
  end

  def display_name_or_fallback
    display_name.presence || name.presence || email.split("@").first
  end

  def initials
    display_name_or_fallback.split(/[\s_-]/).first(2).map { |w| w[0]&.upcase }.compact.join
  end

  def avatar_displayable?
    avatar.attached? && avatar.variable?
  end

  private

  def acceptable_avatar
    return unless attachment_changes["avatar"].present?
    return if ALLOWED_AVATAR_CONTENT_TYPES.include?(avatar.content_type)

    errors.add(:avatar, "must be a JPEG, PNG, GIF, or WebP image")
  end
end
