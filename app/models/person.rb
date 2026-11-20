# One human, sitting above the rows that describe them: a sign-in account
# (User), an attendee profile (Participant) and a parent or guardian record
# (Guardian). Those tables stay the source of truth for now. This only records
# which of them are the same person, and the addresses and numbers they are
# reachable on.
#
# Rows are joined to a person by `identity:backfill` (Identity::Backfill),
# which refuses anything ambiguous and files it as an IdentityReview instead.
class Person < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_many :email_addresses, dependent: :destroy
  has_many :phone_numbers, dependent: :destroy
  has_many :users, dependent: :nullify
  has_many :participants, dependent: :nullify
  has_many :guardians, dependent: :nullify

  # Nobody points at these any more, e.g. after a privacy erasure.
  scope :unattached, -> { where.missing(:users).where.missing(:participants).where.missing(:guardians) }

  def primary_email_address
    email_addresses.find_by(primary: true)
  end
end
