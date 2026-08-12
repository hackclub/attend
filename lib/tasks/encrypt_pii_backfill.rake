namespace :encrypt_pii do
  desc "Re-encrypt existing plaintext PII so `encrypts` attributes are stored as ciphertext"
  task backfill: :environment do
    unless ActiveRecord::Encryption.config.support_unencrypted_data
      abort <<~MSG
        support_unencrypted_data is disabled. The backfill must be able to read
        legacy plaintext rows to re-encrypt them. Enable it (see
        config/initializers/active_record_encryption.rb) before running.
      MSG
    end

    # model => encrypted attributes that previously held plaintext
    targets = {
      Participant => %i[phone],
      EmergencyContact => %i[name phone],
      Accommodation => %i[gender_identity],
      Guardian => %i[phone address_line_1 address_line_2 city state postal_code country],
      User => %i[oidc_claims phone_number]
    }

    targets.each do |model, attributes|
      updated = 0
      skipped = 0
      failed = 0

      puts "\n=== #{model.name} (#{attributes.join(', ')}) ==="

      model.find_each do |record|
        # Nothing to encrypt if every target attribute is blank.
        if attributes.all? { |attr| record.public_send(attr).blank? }
          skipped += 1
          next
        end

        # Force the encrypting type to re-serialize the current (decrypted /
        # legacy-plaintext) value back to the column as ciphertext. update_columns
        # is intentionally NOT used here — it bypasses the encrypting type and
        # would write plaintext straight back.
        attributes.each { |attr| record.public_send("#{attr}_will_change!") }

        if record.save(validate: false)
          updated += 1
        else
          failed += 1
          warn "  FAILED to save #{model.name}##{record.id}: #{record.errors.full_messages.join('; ')}"
        end
      rescue => e
        failed += 1
        warn "  ERROR on #{model.name}##{record.id}: #{e.class}: #{e.message}"
      end

      puts "Done. Encrypted: #{updated}, Skipped (blank): #{skipped}, Failed: #{failed}"
    end

    puts "\nBackfill complete."
  end
end
