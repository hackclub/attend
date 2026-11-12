# The contact details everyone gives before they start training: who they
# are, how they're connected to the event (whose parent, which school), and
# how to reach them. Asked once per person, not per course, and kept up to
# date from /training/details. Someone signed in with Hack Club Auth starts
# from what their account holds (.prefill_for); someone signed in with an
# emailed code types it all in.
#
# The phone number, address and connection are encrypted: the connection
# often names a child. They're kept out of PaperTrail for the same reason.
class TrainingProfile < ApplicationRecord
  self.implicit_order_column = "created_at"

  CONNECTION_TYPES = {
    "parent_guardian" => "Parent or guardian of a participant",
    "teacher" => "Teacher or school staff",
    "organizer" => "Event organizer",
    "hack_club_staff" => "Hack Club staff",
    "volunteer" => "Volunteer",
    "other" => "Something else"
  }.freeze

  ADDRESS_FIELDS = %i[address_line_1 address_line_2 city state postal_code country].freeze

  has_paper_trail skip: [ :connection_detail, :phone_number, *ADDRESS_FIELDS ]

  belongs_to :user

  encrypts :connection_detail, :phone_number, *ADDRESS_FIELDS

  enum :connection_type, CONNECTION_TYPES.keys.index_by(&:itself), prefix: :connection, validate: true

  normalizes :full_name, :connection_detail, :address_line_1, :address_line_2, :city, :state, :postal_code, :country,
    with: ->(value) { value.to_s.squish.presence }

  validates :full_name, :connection_type, :connection_detail, :phone_number, :address_line_1, :city, :country, presence: true
  validates :full_name, length: { maximum: 200 }
  validates :connection_detail, length: { maximum: 500 }
  validate :phone_number_is_dialable

  before_validation :normalize_phone_number
  after_save :name_user

  # What to fill the form with for someone who hasn't saved details yet:
  # their legal name, phone and primary address from Hack Club Auth, then
  # anything Attend already holds. Nothing for a code sign-in with no history.
  def self.prefill_for(user)
    claims = (user.oidc_claims || {}).to_h.stringify_keys
    address = user.hack_club_auth_addresses.first || {}
    hca_name = [
      claims["legal_first_name"].presence || claims["given_name"],
      claims["legal_last_name"].presence || claims["family_name"]
    ].compact_blank.join(" ")

    {
      full_name: hca_name.presence || user.name.presence,
      phone_number: claims["phone_number"].presence || user.phone_number.presence,
      address_line_1: address["line_1"] || address["street_address"],
      address_line_2: address["line_2"],
      city: address["city"] || address["locality"],
      state: address["state"] || address["region"],
      postal_code: address["postal_code"],
      # HCA sends an ISO code; the form's select lists names.
      country: CountryCodes.normalize(address["country"])
    }.compact_blank
  end

  def connection_label
    CONNECTION_TYPES[connection_type]
  end

  def phone_display
    PhoneNormalizer.national(phone_number)
  end

  def address_lines
    [
      address_line_1,
      address_line_2,
      [ city, state, postal_code ].compact_blank.join(", "),
      country
    ].compact_blank
  end

  private

  def normalize_phone_number
    return if phone_number.blank?

    self.phone_number = PhoneNormalizer.normalize(phone_number) || phone_number.to_s.strip
  end

  def phone_number_is_dialable
    return if phone_number.blank? || PhoneNormalizer.valid?(phone_number)

    errors.add(:phone_number, "isn't one we can call. Include the country code if it's outside the US.")
  end

  # Code sign-ins arrive with no name at all, which leaves staff pages showing
  # an email address. Never overwrites a name from Hack Club Auth.
  def name_user
    user.update_column(:name, full_name) if user.name.blank?
  end
end
