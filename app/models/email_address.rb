# An address a Person is reachable on, always stored stripped and downcased.
#
# Unverified addresses can repeat across people: a parent's inbox typed onto
# each of their children's registrations is normal. A verified address is
# proof of control, so only one person can hold it; the partial unique index
# index_email_addresses_on_verified_address is what enforces that.
class EmailAddress < ApplicationRecord
  self.implicit_order_column = "created_at"

  # The one definition of a normalised address, shared with the email columns
  # on participants, guardians and emergency contacts. Blank stays "" rather
  # than nil: `normalizes` also rewrites query values, and a nil here would
  # turn `where.not(email: [ nil, "" ])` into a different query.
  NORMALIZER = ->(value) { value.to_s.strip.downcase }

  SOURCES = %w[user participant guardian].freeze

  belongs_to :person

  normalizes :address, with: NORMALIZER

  validates :address, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: { scope: :person_id }
  validates :source, inclusion: { in: SOURCES }
  validate :verified_for_one_person, if: :verified?
  validate :one_primary_per_person, if: :primary?

  scope :verified, -> { where.not(verified_at: nil) }
  scope :unverified, -> { where(verified_at: nil) }

  def self.normalize(value)
    NORMALIZER.call(value)
  end

  # NORMALIZER in SQL, for comparing and rewriting stored columns. BTRIM's set
  # is what Ruby's #strip removes (space, \t \n \v \f \r) less NUL, which a
  # Postgres text value cannot hold. NormalizeStoredEmails keeps a literal copy.
  def self.normalized_sql(column = "email")
    "LOWER(BTRIM(#{column}, E' \\t\\n\\x0B\\f\\r'))"
  end

  def verified?
    verified_at.present?
  end

  private

  def verified_for_one_person
    return if address.blank?
    return unless self.class.verified.where(address: address).where.not(id: id).exists?

    errors.add(:address, "is already verified for another person")
  end

  def one_primary_per_person
    return if person_id.blank?
    return unless self.class.where(person_id: person_id, primary: true).where.not(id: id).exists?

    errors.add(:primary, "address is already set for this person")
  end
end
