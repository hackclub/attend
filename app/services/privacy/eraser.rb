module Privacy
  # Finds everyone matching a privacy hub subject and erases what Attend holds
  # on them. See app/services/privacy/README.md for what goes, what stays and why.
  #
  # People show up here as a sign-in account (User), an attendee
  # (Participant, one ParticipantEvent per event), a parent or guardian
  # (Guardian), and loosely as an address we emailed, texted or invited, or
  # an emergency contact on someone else's registration.
  #
  # Anything a human should decide raises ManualReviewRequired before a
  # single row changes: staff accounts, registrations for events that haven't
  # ended, safeguarding records, bans, imports still running, and matches that
  # lead to an account the subject's verified identifiers don't. A foreign key
  # we didn't plan for does the same, so an unexpected reference stops the run
  # rather than leaving half an erasure behind.
  #
  # Matching, the checks and the erasure all run in one transaction, with the
  # matched rows locked first, so a role, incident or registration added
  # mid-run waits for us and then fails its foreign key rather than slipping
  # past the checks.
  #
  # A dry run performs the real erasure inside that transaction, reads the
  # per-table delete counts postgres tracks for it, then rolls back, so dry
  # run and real run report the same numbers. Those counters carry earlier
  # transactions on the same connection until postgres flushes them, so we
  # diff a snapshot. On a real run, attachment files are deleted from storage
  # before the commit: if that fails, everything rolls back and the hub's
  # retry still finds the person.
  class Eraser
    Result = Data.define(:found, :deleted, :retained)

    class ManualReviewRequired < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("privacy erasure needs manual review: #{reason}")
      end
    end

    # Records hanging off a registration, as [model, foreign key]. Most go
    # through ParticipantEvent's dependent: :destroy anyway; listing them here
    # is what lets us find their paper_trail versions, audit logs and
    # attachments.
    REGISTRATION_RECORDS = [
      [ "Accommodation", :participant_event_id ],
      [ "Medical", :participant_event_id ],
      [ "Dietary", :participant_event_id ],
      [ "Accessibility", :participant_event_id ],
      [ "SafeguardingInfo", :participant_event_id ],
      [ "EmergencyContact", :participant_event_id ],
      [ "Consent", :participant_event_id ],
      [ "Travel", :participant_event_id ],
      [ "RoomAssignment", :participant_event_id ],
      [ "RoommatePreference", :participant_event_id ],
      [ "RoommatePreference", :preferred_participant_event_id ],
      [ "RoommateExclusion", :participant_event_id ],
      [ "RoommateExclusion", :excluded_participant_event_id ],
      [ "GroupMembership", :participant_event_id ],
      [ "RegistrationChangeRequest", :participant_event_id ],
      [ "SlackBlastRecipient", :participant_event_id ],
      [ "Note", :participant_event_id ],
      [ "Scan", :participant_event_id ],
      [ "MessageDelivery", :participant_event_id ],
      [ "IncidentParticipant", :participant_event_id ]
    ].freeze

    DOCUSEAL_REASON = "signed waivers and documents stay in DocuSeal as liability records; " \
                      "Attend's copy of the signing status and its link to them are removed".freeze
    UNSIGNED_DOCUSEAL_REASON = "documents sent for signature but never signed stay in DocuSeal; " \
                               "Attend's link to them is removed".freeze
    GUARDIAN_CONSENT_REASON = "documents a guardian signed for a child who stays registered remain on the child's record, " \
                              "with the link to the guardian and their DocuSeal signing reference removed".freeze
    AIRTABLE_REASON = "copies synced to event organisers' Airtable bases are not touched here".freeze

    def initialize(subject, now: Time.current)
      @subject = subject
      @now = now
    end

    # A failure the hub should retry, answered with a 503
    class Unavailable < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super("privacy erasure couldn't finish: #{code}")
      end
    end

    # review: false skips the manual-review checks, for exports: those only
    # ever run as a dry run, and should still say what we hold. Staff accounts
    # and identity conflicts still need a human: a staff dry run can't get past
    # the records that reference them, and a conflict would report someone
    # else's data.
    def call(dry_run:, review: true)
      result = Result.new(found: false, deleted: {}, retained: [])
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '5s'")
        @people = lock_people!
        next unless found?

        review ? check_review! : (raise ManualReviewRequired, "staff_account" if staff?)
        retained = retained_counts
        before = delete_counters
        blobs = PaperTrail.request(enabled: false) { erase! }
        scrubbed = scrub_imports!
        deleted = delete_counters.filter_map { |table, count| [ table, count - before.fetch(table, 0) ] if count > before.fetch(table, 0) }.to_h
        result = Result.new(found: true, deleted: deleted.merge(scrubbed), retained:)
        raise ActiveRecord::Rollback if dry_run

        delete_files!(blobs)
      end
      result
    rescue ActiveRecord::InvalidForeignKey
      raise ManualReviewRequired, "unexpected_reference"
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
      raise Unavailable, "database_busy"
    end

    private

    attr_reader :people

    People = Data.define(
      :users, :participants, :participant_events, :guardians, :guardian_links,
      :emails, :phones, :emergency_contacts, :invitations, :email_logs,
      :message_deliveries, :sms_logs, :tickets, :import_batches
    )

    # matches, then locks what it matched and matches again. If the match
    # moved while we waited for the locks, it goes round again
    def lock_people!
      3.times do
        people = match
        lock!(people)
        return people if match == people
      end
      raise Unavailable, "database_busy"
    end

    # FOR UPDATE on the people, so nothing new can reference them or change
    # their roles until we're done, and FOR SHARE on their events, so an
    # event's dates can't move under the event_not_over check
    def lock!(people)
      User.where(id: people.users).order(:id).lock.pluck(:id)
      Participant.where(id: people.participants).order(:id).lock.pluck(:id)
      ParticipantEvent.where(id: people.participant_events).order(:id).lock.pluck(:id)
      Guardian.where(id: people.guardians).order(:id).lock.pluck(:id)
      GuardianParticipantEvent.where(id: people.guardian_links).order(:id).lock.pluck(:id)
      ImportBatch.where(id: people.import_batches).order(:id).lock.pluck(:id)
      Event.where(id: event_ids(people)).order(:id).lock("FOR SHARE").pluck(:id)
    end

    # Accounts are matched only on what Hack Club Auth vouches for: the
    # identity, the email it syncs at sign-in, and its Slack ID. Profiles and
    # guardians are also matched on the email or Slack ID they carry, which
    # anyone can type; one of those that belongs to an account we didn't
    # match is someone else's, so that stops the run instead.
    def match
      emails = @subject.emails
      slack_id = @subject.slack_id
      identity_id = @subject.identity_id

      users = email_in(User, :email, emails)
      users = users.or(User.where(hack_club_account_id: identity_id)) if identity_id
      user_ids = users.pluck(:id)
      # slack_user_id is a profile override, so it only counts where HCA agrees
      user_ids |= User.where(slack_user_id: slack_id).select { |user| user.verified_slack_id == slack_id }.map(&:id) if slack_id
      conflict! if identity_id && User.where(id: user_ids).where.not(hack_club_account_id: [ nil, identity_id ]).exists?

      participants = email_in(Participant, :email, emails)
      participants = participants.or(Participant.where(slack_user_id: slack_id)) if slack_id
      conflict! if participants.where.not(user_id: nil).where.not(user_id: user_ids).exists?
      # a Slack ID on a registration was typed by whoever registered them,
      # often an organiser, so it isn't evidence of whose profile it is
      if slack_id
        conflict! if Participant.where(id: ParticipantEvent.where(slack_user_id: slack_id).select(:participant_id))
                                .where.not(id: participants.or(Participant.where(user_id: user_ids)).select(:id)).exists?
      end
      participant_ids = participants.or(Participant.where(user_id: user_ids)).pluck(:id)
      participant_event_ids = ParticipantEvent.where(participant_id: participant_ids).pluck(:id)

      # guardians matched directly, plus anyone whose only reason to be here
      # is a child being erased: with the registration gone, their details
      # serve nothing
      guardians = email_in(Guardian, :email, emails)
      conflict! if guardians.where.not(user_id: nil).where.not(user_id: user_ids).exists?
      matched_guardian_ids = guardians.or(Guardian.where(user_id: user_ids)).pluck(:id)
      linked_guardian_ids = GuardianParticipantEvent.where(participant_event_id: participant_event_ids).distinct.pluck(:guardian_id)
      orphaned_guardian_ids = Guardian.where(id: linked_guardian_ids)
                                      .where.not(id: GuardianParticipantEvent.where.not(participant_event_id: participant_event_ids).select(:guardian_id))
                                      .pluck(:id)
      guardian_ids = (matched_guardian_ids + orphaned_guardian_ids).uniq
      guardian_link_ids = GuardianParticipantEvent.where(participant_event_id: participant_event_ids)
                                                  .or(GuardianParticipantEvent.where(guardian_id: guardian_ids)).pluck(:id)

      all_emails = (emails +
        User.where(id: user_ids).pluck(:email) +
        Participant.where(id: participant_ids).pluck(:email) +
        Guardian.where(id: guardian_ids).pluck(:email)).compact.map { |email| email.strip.downcase }.compact_blank.uniq
      # phones are encrypted, so they're read back through the models. A child
      # often gives a parent's number, so a phone anyone staying on file also
      # has is never used to match: it would sweep up their texts and tickets
      phones = (User.where(id: user_ids).map(&:phone_number) +
        Participant.where(id: participant_ids).map(&:phone) +
        Guardian.where(id: guardian_ids).map(&:phone)).compact_blank.uniq
      # users' numbers aren't deterministically encrypted, so they're
      # decrypted and compared here rather than queried
      other_user_phones = phones.any? ? User.where.not(id: user_ids).where.not(phone_number: nil).pluck(:phone_number).to_set : Set.new
      phones = phones.reject do |phone|
        other_user_phones.include?(phone) ||
          Participant.where(phone:).where.not(id: participant_ids).exists? ||
          Guardian.where(phone:).where.not(id: guardian_ids).exists? ||
          EmergencyContact.where(phone:).where.not(id: EmergencyContact.where(participant_event_id: participant_event_ids).select(:id)).exists?
      end

      # a ticket filed against someone else stays, even from a shared number
      tickets = Ticket.where(subject_type: "Participant", subject_id: participant_ids)
                      .or(Ticket.where(subject_type: "Guardian", subject_id: guardian_ids))
      tickets = tickets.or(Ticket.where(subject_id: nil, phone_number: phones)) if phones.any?

      people = {
        users: user_ids,
        participants: participant_ids,
        participant_events: participant_event_ids,
        guardians: guardian_ids,
        guardian_links: guardian_link_ids,
        emails: all_emails,
        phones: phones,
        # someone listed as an emergency contact is matched on the emails the
        # hub sent for them only, not on the emails of everyone being erased
        emergency_contacts: email_in(EmergencyContact, :email, emails)
                                            .or(EmergencyContact.where(participant_event_id: participant_event_ids))
                                            .or(EmergencyContact.where(guardian_participant_event_id: guardian_link_ids)).pluck(:id),
        invitations: email_in(Invitation, :email, all_emails).pluck(:id),
        email_logs: email_in(EmailLog, :to_address, all_emails)
                            .or(EmailLog.where(emailable_id: user_ids + participant_ids + participant_event_ids + guardian_ids + guardian_link_ids)).pluck(:id),
        message_deliveries: email_in(MessageDelivery, :recipient_email, all_emails)
                                           .or(MessageDelivery.where(participant_event_id: participant_event_ids))
                                           .or(MessageDelivery.where(guardian_id: guardian_ids)).pluck(:id),
        sms_logs: phones.any? ? AutomatedSmsLog.where(phone_number: phones).pluck(:id) : [],
        tickets: tickets.pluck(:id),
        import_batches: import_batch_ids(all_emails)
      }
      People.new(**people.transform_values(&:sort))
    end

    def conflict!
      raise ManualReviewRequired, "identity_conflict"
    end

    # an empty list matches nothing. Matching on "" instead would sweep up
    # every row whose email is blank
    def email_in(model, column, emails)
      emails = emails.compact_blank
      return model.where("1=0") if emails.empty?

      model.where("lower(#{model.connection.quote_column_name(column)}) IN (?)", emails)
    end

    def found?
      people.to_h.except(:emails, :phones).values.any?(&:present?)
    end

    def check_review!
      raise ManualReviewRequired, "staff_account" if staff?
      raise ManualReviewRequired, "event_not_over" if open_registration?
      raise ManualReviewRequired, "safeguarding_record" if safeguarding_record?
      raise ManualReviewRequired, "banned" if email_in(BanEmail, :email, people.emails).exists?
      # a running import would write its copy of their row back
      raise ManualReviewRequired, "import_in_progress" if ImportBatch.where(id: people.import_batches).where.not(status: %w[previewing completed failed]).exists?
    end

    # staff accounts authored incidents, notes, messages and audit history
    # that other people's records depend on, and may hold API tokens other
    # services use
    def staff?
      users = people.users
      return false if users.empty?

      User.where(id: users).where.not(global_role: "none").exists? ||
        EventRoleAssignment.where(user_id: users).exists? ||
        SeriesRoleAssignment.where(user_id: users).exists? ||
        EventApiToken.where(user_id: users).exists? ||
        SeriesApiToken.where(user_id: users).exists? ||
        GlobalApiToken.where(user_id: users).exists?
    end

    # erasing someone from an event that's still to come, or underway, takes
    # them out of the organisers' headcount, rooming and medical lists, so the
    # organisers remove the registration first
    def open_registration?
      Event.where(id: event_ids(people)).where("COALESCE(ends_at, starts_at) IS NULL OR COALESCE(ends_at, starts_at) > ?", @now).exists?
    end

    # every event the people being erased are registered for, guard, or are
    # an emergency contact at
    def event_ids(people)
      (ParticipantEvent.where(id: people.participant_events).pluck(:event_id) +
        GuardianParticipantEvent.where(id: people.guardian_links).joins(:participant_event).pluck("participant_events.event_id") +
        EmergencyContact.where(id: people.emergency_contacts).filter_map { |contact| (contact.participant_event || contact.guardian_participant_event&.participant_event)&.event_id }).uniq
    end

    # safeguarding records are kept on their own retention schedule, and the
    # safeguarding lead decides what happens to them
    def safeguarding_record?
      users = people.users
      pes = people.participant_events
      Incident.where(participant_event_id: pes).exists? ||
        IncidentParticipant.where(participant_event_id: pes).exists? ||
        IncidentReport.where(user_id: users).or(email_in(IncidentReport, :reporter_email, people.emails)).exists? ||
        IncidentHelpingStaff.where(user_id: users).exists? ||
        IncidentComment.where(user_id: users).exists? ||
        IncidentReportComment.where(user_id: users).exists?
    end

    def retained_counts
      retained = []
      envelopes = Consent.where(participant_event_id: people.participant_events).where.not(docuseal_envelope_id: nil)
      signed = envelopes.where(status: "signed").count
      retained << { type: "signed documents", count: signed, reason: DOCUSEAL_REASON } if signed.positive?
      unsigned = envelopes.where.not(status: "signed").count
      retained << { type: "unsigned documents", count: unsigned, reason: UNSIGNED_DOCUSEAL_REASON } if unsigned.positive?

      kept = surviving_guardian_consents.count
      retained << { type: "guardian-signed documents", count: kept, reason: GUARDIAN_CONSENT_REASON } if kept.positive?

      synced = ParticipantEvent.where(id: people.participant_events).where.not(airtable_record_id: nil).count +
        GuardianParticipantEvent.where(id: people.guardian_links).where.not(airtable_record_id: nil).count +
        Accommodation.where(participant_event_id: people.participant_events).where.not(airtable_record_id: nil).count
      retained << { type: "airtable copies", count: synced, reason: AIRTABLE_REASON } if synced.positive?
      retained
    end

    def erase!
      ids = record_ids
      blobs = erase_attachments!(ids)

      pes = people.participant_events
      users = people.users

      # cleared first: audit_logs.actor_user_id is a foreign key, so the
      # user can't go while an entry still names them
      PaperTrail::Version.where(whodunnit: users).update_all(whodunnit: nil) if users.any?
      AuditLog.where(actor_user_id: users).update_all(actor_user_id: nil) if users.any?

      # before the guardian links go, while these can still be found
      scrub_guardian_from_consents!

      # these hang off a registration or account without a dependent: :destroy
      Note.where(participant_event_id: pes).or(Note.where(ticket_id: people.tickets)).delete_all
      # hospitality and nfc_tokens are tables from features since removed, with no models left
      execute([ "DELETE FROM hospitality_acts WHERE participant_event_id IN (?) OR user_id IN (?)", pes.presence || [ nil ], users.presence || [ nil ] ])
      execute([ "DELETE FROM hospitality_redemptions WHERE user_id IN (?)", users.presence || [ nil ] ])
      passes = Passkit::Pass.where(generator_type: "ParticipantEvent", generator_id: pes)
      Passkit::Registration.where(passkit_pass_id: passes.select(:id)).delete_all
      passes.delete_all

      Ticket.where(merged_into_id: people.tickets).where.not(id: people.tickets).update_all(merged_into_id: nil)
      Ticket.where(id: people.tickets).destroy_all
      EmergencyContact.where(id: people.emergency_contacts).destroy_all
      Invitation.where(id: people.invitations).destroy_all
      EmailLog.where(id: people.email_logs).destroy_all
      MessageDelivery.where(id: people.message_deliveries).destroy_all
      AutomatedSmsLog.where(id: people.sms_logs).delete_all

      Participant.where(id: people.participants).destroy_all
      Guardian.where(id: people.guardians).destroy_all

      BadgeRedirect.where(user_id: users).delete_all
      execute([ "DELETE FROM nfc_tokens WHERE user_id IN (?)", users.presence || [ nil ] ])
      # MCP grants and tokens name their owner as a string, with no foreign key
      owners = users.map(&:to_s).presence || [ nil ]
      %w[toolchest_oauth_access_grants toolchest_oauth_access_tokens mcp_connection_settings].each do |table|
        execute([ "DELETE FROM #{table} WHERE resource_owner_id IN (?)", owners ])
      end
      User.where(id: users).destroy_all

      PaperTrail::Version.where(item_id: ids).delete_all
      AuditLog.where(record_id: ids).delete_all

      blobs
    end

    # attachment, variant and blob rows go now; the files they point at go
    # in delete_files! on a real run. A blob something else still has
    # attached stays
    def erase_attachments!(ids)
      attachments = ActiveStorage::Attachment.where(record_id: ids)
      blob_ids = attachments.pluck(:blob_id)
      attachments.delete_all
      blobs = ActiveStorage::Blob.where(id: blob_ids).where.not(id: ActiveStorage::Attachment.select(:blob_id)).to_a

      variants = ActiveStorage::VariantRecord.where(blob_id: blobs.map(&:id))
      variant_attachments = ActiveStorage::Attachment.where(record_type: "ActiveStorage::VariantRecord", record_id: variants.pluck(:id).map(&:to_s))
      variant_blobs = ActiveStorage::Blob.where(id: variant_attachments.pluck(:blob_id)).to_a
      variant_attachments.delete_all
      variants.delete_all
      ActiveStorage::Blob.where(id: (blobs + variant_blobs).map(&:id)).delete_all
      blobs + variant_blobs
    end

    def delete_files!(blobs)
      blobs.each(&:delete)
    rescue StandardError => e
      Rails.logger.error("[Privacy] deleting attachment files failed: #{e.class}")
      raise Unavailable, "storage_unavailable"
    end

    IMPORT_CONTACTS = {
      "parent_email" => %w[parent_first_name parent_last_name parent_email parent_phone],
      "emergency_email" => %w[emergency_first_name emergency_last_name emergency_email emergency_phone emergency_relationship]
    }.freeze

    # import batches hold the CSV rows an organiser uploaded until the import
    # finishes, and the per-row errors after. Narrowed with a text search,
    # then checked field by field
    def import_batch_ids(emails)
      return [] if emails.empty?

      patterns = emails.map { |email| "%#{ImportBatch.sanitize_sql_like(email)}%" }
      ImportBatch.where("lower(rows_data::text) LIKE ANY (ARRAY[?]) OR lower(errors_data::text) LIKE ANY (ARRAY[?])", patterns, patterns)
                 .select { |batch| scrubbed_import(batch, emails).present? }.map(&:id)
    end

    # the batch's rows and errors without the people being erased: their
    # own rows go, and their details come off rows where they're the parent
    # or emergency contact. nil when there's nothing of theirs
    def scrubbed_import(batch, emails)
      erased = ->(value) { value.is_a?(String) && emails.include?(value.strip.downcase) }
      mentioned = ->(text) { text.is_a?(String) && emails.any? { |email| text.match?(/(?<![\w.+-])#{Regexp.escape(email)}(?![\w-])/i) } }

      rows = batch.rows_data.reject { |row| erased.(row["email"]) }.map do |row|
        IMPORT_CONTACTS.reduce(row) { |kept, (field, fields)| erased.(kept[field]) ? kept.except(*fields) : kept }
      end
      errors = batch.errors_data.reject { |error| erased.(error["email"]) || mentioned.(error["error"]) }
      return if rows == batch.rows_data && errors == batch.errors_data

      { rows:, errors:, rows_changed: batch.rows_data.count { |row| !rows.include?(row) }, errors_removed: batch.errors_data.size - errors.size }
    end

    def scrub_imports!
      counts = Hash.new(0)
      ImportBatch.where(id: people.import_batches).find_each do |batch|
        scrubbed = scrubbed_import(batch, people.emails)
        next unless scrubbed

        batch.update_columns(rows_data: scrubbed[:rows], errors_data: scrubbed[:errors], updated_at: @now)
        counts["import_batches.rows_data"] += scrubbed[:rows_changed]
        counts["import_batches.errors_data"] += scrubbed[:errors_removed]
      end
      counts.select { |_, count| count.positive? }
    end

    # every row about to go whose paper_trail versions, audit logs or
    # attachments have to go with it. Ids are uuids, so one list covers all
    # the tables
    def record_ids
      pes = people.participant_events
      ids = people.users + people.participants + pes + people.guardians + people.guardian_links +
        people.emergency_contacts + people.invitations + people.tickets
      REGISTRATION_RECORDS.each { |model, column| ids.concat(model.constantize.where(column => pes).pluck(:id)) }
      ids.concat(TravelLeg.where(travel_id: Travel.where(participant_event_id: pes).select(:id)).pluck(:id))
      ids.concat(SiblingMembership.where(participant_id: people.participants).pluck(:id))
      ids.concat(TicketMessage.where(ticket_id: people.tickets).pluck(:id))
      ids.concat(Note.where(ticket_id: people.tickets).pluck(:id))
      ids.uniq
    end

    # consents a guardian being erased signed for a child who isn't. The
    # guardian link is nullified and their signing slug cleared; the consent,
    # with its uploads, stays
    def surviving_guardian_consents
      Consent.where(guardian_participant_event_id: people.guardian_links).where.not(participant_event_id: people.participant_events)
    end

    GUARDIAN_CONSENT_COLUMNS = %w[guardian_participant_event_id docuseal_guardian_slug].freeze

    # takes the guardian out of kept consents and their history. Versions are
    # YAML text, so they're rewritten one by one; the rest of each version,
    # and the child's side of the consent, is left as it was
    def scrub_guardian_from_consents!
      consent_ids = surviving_guardian_consents.pluck(:id)
      return if consent_ids.empty?

      Consent.where(id: consent_ids).update_all(docuseal_guardian_slug: nil)
      serializer = PaperTrail.serializer
      PaperTrail::Version.where(item_type: "Consent", item_id: consent_ids).find_each do |version|
        object = version.object && serializer.load(version.object)
        changes = version.object_changes && serializer.load(version.object_changes)
        GUARDIAN_CONSENT_COLUMNS.each { |column| object[column] = nil if object&.key?(column) }
        changes&.except!(*GUARDIAN_CONSENT_COLUMNS)
        version.update_columns(object: object && serializer.dump(object), object_changes: changes && serializer.dump(changes))
      end
    end

    def execute(statement)
      ActiveRecord::Base.connection.exec_delete(ActiveRecord::Base.sanitize_sql(statement))
    end

    def delete_counters
      rows = ActiveRecord::Base.connection.select_rows(<<~SQL)
        SELECT relname, n_tup_del FROM pg_stat_xact_user_tables
        WHERE n_tup_del > 0 AND relname NOT LIKE 'solid_%' ORDER BY relname
      SQL
      rows.to_h { |table, count| [ table, count.to_i ] }
    end
  end
end
