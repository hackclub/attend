# Active Record encryption transition settings.
#
# Several columns gained `encrypts` (participant.phone, emergency_contact.name,
# emergency_contact.phone, accommodation.gender_identity, guardian phone/address
# fields, user.oidc_claims and user.phone_number — plus the pre-existing Medical
# attributes). Existing production rows may still hold *plaintext*
# values, so support_unencrypted_data must stay enabled until the backfill
# (`bin/rails encrypt_pii:backfill`) has run on every environment:
#
#   * support_unencrypted_data — lets reads return legacy plaintext instead of
#     raising ActiveRecord::Encryption::Errors::Decryption. Without it, every
#     un-backfilled row (safeguarding pages, rooming logic, etc.) would 500.
#
# NOTE: extend_queries is intentionally NOT enabled.
#
# `accommodation.gender_identity` is both a Rails `enum` and a deterministically
# encrypted attribute. extend_queries builds the model's
# `deterministic_encrypted_attributes` list by calling `.deterministic?` on
# `type_for_attribute(name)`, but for an enum-backed column that returns
# `ActiveRecord::Enum::EnumType`, which does not define `deterministic?`. With
# extend_queries on, *any* query against such a model (e.g. preloading
# accommodations on the admin dashboard) raises NoMethodError. So it stays off.
#
# Consequence: deterministic equality queries (Participant.where(phone:), Ticket
# phone routing, the gender_identity enum scopes) match only already-encrypted
# rows, not legacy plaintext. The backfill MUST be run so every row is encrypted;
# afterwards these lookups match everything. Until then, reads still work (via
# support_unencrypted_data) — only equality lookups against not-yet-encrypted
# rows silently miss.
#
# Deploy sequence:
#   1. Deploy (encryption keys must exist in credentials under
#      active_record_encryption — the Medical model has used `encrypts` for a
#      while, so they should; confirm with `bin/rails db:encryption:init`).
#   2. Run `bin/rails encrypt_pii:backfill` to encrypt existing rows.
#   3. Once every environment is backfilled, support_unencrypted_data can be
#      flipped to false in a follow-up to fail closed on any stray plaintext.
Rails.application.config.active_record.encryption.support_unencrypted_data = true
