# Puts an email into a row exactly as typed, the way rows written before
# emails were normalised on save still hold them. `update_column` and a hash
# `update_all` both go through the attribute type, which normalises, so this
# has to be a SQL string.
module LegacyEmail
  def store_legacy_email(record, email)
    record.class.where(id: record.id).update_all([ "email = ?", email ])
    record.reload
  end
end

RSpec.configure { |config| config.include LegacyEmail }
