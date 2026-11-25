# A set of rows `identity:backfill` would not join into one Person on its own:
# same-address participants whose names or birth dates disagree, guardians
# sharing an inbox under different names, and so on. A human decides.
#
# Holds record ids only. The address the rows share is never stored; the
# fingerprint is a digest of it, there so a re-run updates the same review
# rather than filing another.
class IdentityReview < ApplicationRecord
  self.implicit_order_column = "created_at"

  CATEGORIES = %w[
    linked_participants
    linked_guardians
    participant_account_email
    participant_duplicates
    guardian_duplicates
    guardian_overlap
    verified_email_conflict
  ].freeze

  validates :category, inclusion: { in: CATEGORIES }
  validates :fingerprint, presence: true, uniqueness: true

  scope :open, -> { where(resolved_at: nil) }
  # Reviews naming any of these record ids, whichever table they belong to.
  scope :naming, ->(ids) {
    where("user_ids && ARRAY[:ids]::uuid[] OR participant_ids && ARRAY[:ids]::uuid[] OR guardian_ids && ARRAY[:ids]::uuid[]", ids: ids)
  }

  def self.fingerprint_for(category, key)
    Digest::SHA256.hexdigest("#{category}:#{key}")
  end
end
