# Someone asking for a visa invitation letter to an event, moved here from
# Envoy. The letter comes before a place at the event: staff review the
# application, the letter is issued, the embassy decides, and only someone
# whose visa is granted is offered a place. So this belongs to the event, and
# links to a registration only once there is one (`participant_event`).
#
# Applicants sign in with Hack Club Auth, so a new application always has a
# user. Applications imported from Envoy don't until their owner signs in and
# claims them; `imported_at` marks those, and relaxes the checks on details
# Envoy never required.
#
# Everything the letter prints is frozen once it's sent (FROZEN_ONCE_SENT):
# embassies check letters against /verify, which reads this row.
class VisaLetterApplication < ApplicationRecord
  include NormalizesPhoneNumbers

  class InvalidTransition < StandardError; end

  # The applicant's details are encrypted; a version would store them in plaintext.
  has_paper_trail skip: %i[full_name email nationality place_of_birth phone address]

  self.implicit_order_column = "created_at"

  # Deterministic so the privacy hub can find an applicant by email.
  encrypts :email, deterministic: true
  encrypts :full_name, :nationality, :place_of_birth, :phone, :address
  # Declared after `encrypts`, so the address is normalized before it's
  # encrypted, and lookups by email are normalized the same way.
  normalizes :email, with: ->(email) { email.strip.downcase }

  belongs_to :event
  belongs_to :user, optional: true
  belongs_to :participant_event, optional: true
  belongs_to :invitation, optional: true
  belongs_to :visa_letter_invitation, optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true
  has_one_attached :letter_pdf

  enum :status, { pending: "pending", approved: "approved", rejected: "rejected", letter_sent: "letter_sent" }
  enum :rejection_type, { soft: "soft", hard: "hard" }, prefix: :rejection
  enum :visa_outcome, { unknown: "unknown", granted: "granted", denied: "denied" }, prefix: :visa

  FROZEN_ONCE_SENT = %w[
    event_id full_name email date_of_birth nationality place_of_birth phone address
    reference_number verification_code letter_event_name letter_venue letter_address
    letter_city letter_country letter_starts_on letter_ends_on letter_issued_on
  ].freeze

  validates :full_name, :email, :date_of_birth, :nationality, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :place_of_birth, :phone, :address, presence: true, unless: :imported?
  validates :phone, e164_phone: true, allow_blank: true, unless: :imported?
  validates :user, presence: true, on: :create, unless: :imported?
  validates :user_id, uniqueness: { scope: :event_id }, allow_nil: true
  validates :reference_number, :verification_code, presence: true, uniqueness: true
  validates :rejection_type, :rejection_reason, presence: true, if: :rejected?
  validate :date_of_birth_in_past
  validate :applicant_not_banned, on: :create
  validate :letter_unchanged, on: :update

  normalizes_phone_number :phone

  before_validation :assign_reference_number, :assign_verification_code, on: :create
  before_validation(on: :create) { self.submitted_at ||= Time.current }

  def imported?
    imported_at.present?
  end

  def hard_rejected?
    rejected? && rejection_hard?
  end

  def soft_rejected?
    rejected? && rejection_soft?
  end

  def approve!(by:, notes: nil)
    raise InvalidTransition, "only a pending application can be approved" unless pending?
    # A ban can arrive after someone applies.
    raise InvalidTransition, "the applicant is banned from events" if Ban.banned?(email)

    update!(status: :approved, reviewed_by: by, reviewed_at: Time.current, admin_notes: notes.presence || admin_notes)
  end

  def reject!(by:, reason:, type: :soft, notes: nil)
    raise InvalidTransition, "only a pending application can be rejected" unless pending?

    update!(status: :rejected, rejection_type: type, rejection_reason: reason,
      reviewed_by: by, reviewed_at: Time.current, admin_notes: notes.presence || admin_notes)
  end

  # Lets someone whose hard rejection was a mistake apply again.
  def downgrade_rejection!
    raise InvalidTransition, "only a hard rejection can be downgraded" unless hard_rejected?

    update!(rejection_type: :soft)
  end

  # Freezes what the letter says, renders it and attaches it. The caller
  # sends it. Raises when no template applies, rather than leaving the
  # application approved with no letter, which is what Envoy did.
  def issue_letter!(template: VisaLetterTemplate.for_event(event), issued_on: Date.current)
    raise InvalidTransition, "only an approved application can be issued a letter" unless approved?
    raise InvalidTransition, "there's no active visa letter template for #{event.name}" if template.nil?

    snapshot_letter_details(issued_on)
    pdf = VisaLetterPdfService.new(self, template: template).generate
    self.letter_pdf = { io: StringIO.new(pdf), filename: "visa-letter-#{reference_number}.pdf", content_type: "application/pdf" }
    self.status = :letter_sent
    self.letter_sent_at = Time.current
    save!
  end

  # Applying again after a rejection: the same application goes back to
  # review with the corrected details. Only a soft rejection allows it, unless
  # staff have since invited them to apply (`overriding_hard_rejection`).
  # An Envoy import sent again through Attend's form is Attend's from then on,
  # so it gets Attend's checks rather than Envoy's.
  def resubmit!(attributes, overriding_hard_rejection: false)
    unless soft_rejected? || (hard_rejected? && overriding_hard_rejection)
      raise InvalidTransition, "only a rejected application can be submitted again"
    end

    update!(attributes.merge(status: :pending, rejection_type: nil, rejection_reason: nil,
      reviewed_by: nil, reviewed_at: nil, submitted_at: Time.current, imported_at: nil))
  end

  # What a new application can start with: the legal details Hack Club Auth
  # holds for the account, then anything their Attend profile has that HCA
  # doesn't. The applicant checks all of it against their passport.
  def self.prefill_for(user)
    claims = (user.oidc_claims || {}).to_h.stringify_keys
    participant = user.participant
    name = [ claims["legal_first_name"].presence || claims["given_name"], claims["legal_last_name"].presence || claims["family_name"] ].compact_blank.join(" ")
    name = participant&.full_name if name.blank? || name.include?(Participant::NAME_PLACEHOLDER)

    {
      full_name: name.presence,
      date_of_birth: participant&.date_of_birth,
      phone: claims["phone_number"].presence || participant&.phone,
      address: participant_address(participant),
      nationality: CountryCodes.normalize(claims.dig("address", "country")) || participant&.country_of_residence.presence
    }.compact.merge(locked_by_hack_club_auth(user))
  end

  # The birthday and mailing address Hack Club Auth holds for the account.
  # Where it has them, the letter uses them as they are: the applicant can't
  # type different ones, and changes them in Hack Club Auth instead.
  def self.locked_by_hack_club_auth(user)
    claims = (user.oidc_claims || {}).to_h.stringify_keys
    {
      date_of_birth: parse_date(claims["birthdate"]),
      address: address_from_claims(claims["address"])
    }.compact
  end

  # Envoy's applications have no account until their owner signs in. A Hack
  # Club account with the same verified email claims them, except where it
  # already has an application for that event.
  def self.claim_imported_for(user)
    return if user.email.blank? || user.hack_club_account_id.blank?

    where(user_id: nil, email: user.email).where.not(imported_at: nil).find_each do |application|
      next if where(event_id: application.event_id, user_id: user.id).exists?

      application.update_columns(user_id: user.id, updated_at: Time.current)
    end
  end

  def self.parse_date(value)
    Date.iso8601(value.to_s) if value.present?
  rescue Date::Error
    nil
  end

  # HCA sends its own address shape, OIDC's standard one, or nothing.
  def self.address_from_claims(address)
    return if address.blank?

    address = address.to_h.stringify_keys
    lines = [
      address["line_1"] || address["street_address"],
      address["line_2"],
      [ address["city"] || address["locality"], address["state"] || address["region"], address["postal_code"] ].compact_blank.join(", "),
      CountryCodes.normalize(address["country"]) || address["country"]
    ]
    lines.compact_blank.join("\n").presence
  end

  def self.participant_address(participant)
    return if participant.nil?

    [ participant.address_line_1, participant.address_line_2,
      [ participant.city, participant.state, participant.postal_code ].compact_blank.join(", "),
      participant.country_of_residence ].compact_blank.join("\n").presence
  end
  private_class_method :parse_date, :address_from_claims, :participant_address

  def record_visa_outcome!(outcome)
    raise InvalidTransition, "the visa outcome can only be recorded once the letter is sent" unless letter_sent?

    update!(visa_outcome: outcome, visa_outcome_recorded_at: Time.current)
  end

  def letter_date_range
    return if letter_starts_on.nil?

    starts = letter_starts_on
    ends = letter_ends_on || starts
    if starts == ends
      starts.strftime("%B %-d, %Y")
    elsif starts.year == ends.year && starts.month == ends.month
      "#{starts.strftime('%B %-d')}–#{ends.strftime('%-d, %Y')}"
    elsif starts.year == ends.year
      "#{starts.strftime('%B %-d')} – #{ends.strftime('%B %-d, %Y')}"
    else
      "#{starts.strftime('%B %-d, %Y')} – #{ends.strftime('%B %-d, %Y')}"
    end
  end

  private

  def snapshot_letter_details(issued_on)
    self.letter_event_name = event.name
    self.letter_venue = event.venue_name
    self.letter_address = event.location_address
    self.letter_city = event.location_city
    self.letter_country = event.location_country
    self.letter_starts_on = event.local_start_date
    self.letter_ends_on = event.local_end_date
    self.letter_issued_on = issued_on
  end

  # Envoy's formats, so imported and new letters look alike.
  def assign_reference_number
    self.reference_number ||= loop do
      candidate = "HC-#{SecureRandom.alphanumeric(8).upcase}"
      break candidate unless self.class.exists?(reference_number: candidate)
    end
  end

  def assign_verification_code
    self.verification_code ||= loop do
      candidate = SecureRandom.hex(16).upcase
      break candidate unless self.class.exists?(verification_code: candidate)
    end
  end

  # Envoy's rule and wording. Imported letters keep whatever Envoy accepted.
  def date_of_birth_in_past
    return if date_of_birth.blank?

    if date_of_birth >= Date.current
      errors.add(:date_of_birth, "must be in the past")
    elsif !imported? && date_of_birth > 13.years.ago.to_date
      errors.add(:date_of_birth, "must be at least 13 years old")
    end
  end

  def applicant_not_banned
    errors.add(:email, "is banned from events") if email.present? && Ban.banned?(email)
  end

  def letter_unchanged
    return unless status_in_database == "letter_sent"

    changed_fields = FROZEN_ONCE_SENT & changed
    changed_fields.each { |field| errors.add(field, "can't change once the letter has been sent") }
  end
end
