namespace :phone do
  # Every model/attribute holding a number someone is actually dialled on.
  # Resolved lazily: the constants don't exist until :environment has run.
  def self.targets
    [
      [ Participant,      :phone ],
      [ Guardian,         :phone ],
      [ EmergencyContact, :phone ],
      [ IncidentReport,   :reporter_phone ],
      [ User,             :phone_number ],
      [ Ticket,           :phone_number ]
    ]
  end

  desc "Report stored phone numbers that aren't valid E.164 (no writes)"
  task audit: :environment do
    total = 0

    targets.each do |model, attribute|
      bad = []

      model.find_each do |record|
        raw = record.public_send(attribute)
        next if raw.blank?
        next if raw == PhoneNormalizer.normalize(raw)

        bad << [ record.id, raw, PhoneNormalizer.normalize(raw) ]
      end

      total += bad.size
      puts "\n#{model.name}##{attribute}: #{bad.size} non-canonical"
      bad.each do |id, raw, fixed|
        # Repairable means we can derive E.164; nil means someone has to ask
        # the person for a working number.
        puts "  #{id}  #{raw.inspect} -> #{fixed ? fixed : 'UNREPAIRABLE'}"
      end
    end

    puts "\n#{total} record(s) hold a non-canonical phone number."
    puts "Run `rake phone:repair` to rewrite the repairable ones."
  end

  desc "Rewrite stored phone numbers to E.164 where possible (dry run unless APPLY=1)"
  task repair: :environment do
    apply = ENV["APPLY"] == "1"
    repaired = 0
    unrepairable = 0

    targets.each do |model, attribute|
      model.find_each do |record|
        raw = record.public_send(attribute)
        next if raw.blank?

        fixed = PhoneNormalizer.normalize(raw)
        next if fixed == raw

        if fixed.nil?
          unrepairable += 1
          puts "SKIP #{model.name}##{record.id} #{raw.inspect} — cannot be parsed, needs a human"
          next
        end

        repaired += 1
        puts "#{model.name}##{record.id} #{raw.inspect} -> #{fixed}"
        next unless apply

        # Skip validations: an unrelated pre-existing problem on the row
        # must not stop us from canonicalising the phone number.
        record.public_send(:"#{attribute}=", fixed)
        record.save!(validate: false)
      end
    end

    puts "\n#{apply ? 'Repaired' : 'Would repair'} #{repaired} record(s); #{unrepairable} need a human."
    puts "Dry run — re-run with APPLY=1 to write changes." unless apply
  end
end
