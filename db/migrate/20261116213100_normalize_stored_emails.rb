# Participant, guardian and emergency contact emails are now stripped and
# downcased on write (`normalizes :email`), and `normalizes` rewrites query
# values too. A row still stored mixed-case would stop matching
# `where(email: ...)`, so an import re-run under the same address would add a
# second participant. This brings the stored rows in line in the same deploy.
#
# Plain SQL on purpose: a case-only rewrite should not run validations, fan
# out callbacks or write versions, and none of these columns is unique, so it
# cannot fail on a collision. Rows that end up sharing an address with another
# row already matched case-insensitively; `identity:backfill` sorts those out.
# Safe to run again, and `identity:normalize_emails` does the same on demand.
class NormalizeStoredEmails < ActiveRecord::Migration[8.1]
  TABLES = %w[participants guardians emergency_contacts].freeze
  # A copy of EmailAddress.normalized_sql (migrations don't load app code):
  # the characters Ruby's #strip removes, less NUL.
  NORMALISED = "LOWER(BTRIM(email, E' \\t\\n\\x0B\\f\\r'))".freeze

  def up
    TABLES.each do |table|
      execute <<~SQL.squish
        UPDATE #{table} SET email = #{NORMALISED}
        WHERE email IS NOT NULL AND email <> #{NORMALISED}
      SQL
    end
  end

  # The original casing is not kept anywhere, and nothing depends on it.
  def down
  end
end
