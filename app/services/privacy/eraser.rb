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
  # ended, safeguarding records and bans. A foreign key we didn't plan for
  # does the same, so an unexpected reference stops the run rather than
  # leaving half an erasure behind.
  #
  # A dry run performs the real erasure inside a transaction, reads the
  # per-table delete counts postgres tracks for that transaction, then rolls
  # back, so dry run and real run report the same numbers. Those counters
  # carry earlier transactions on the same connection until postgres flushes
  # them, so we diff a snapshot. Attachment blobs are purged only after a real
  # run commits.
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
    AIRTABLE_REASON = "copies synced to event organisers' Airtable bases are not touched here".freeze

    def initialize(subject, now: Time.current)
      @subject = subject
      @now = now
    end

    # review: false skips the manual-review checks, for exports: those only
    # ever run as a dry run, and should still say what we hold. Staff accounts
    # still need a human, since their dry run can't get past the records that
    # reference them.
    def call(dry_run:, review: true)
      @people = match
      return Result.new(found: false, deleted: {}, retained: []) unless found?

      review ? check_review! : (raise ManualReviewRequired, "staff_account" if staff?)
      retained = retained_counts
      deleted = {}
      blob_ids = []
      ActiveRecord::Base.transaction do
        before = delete_counters
        PaperTrail.request(enabled: false) { blob_ids = erase! }
        deleted = delete_counters.filter_map { |table, count| [ table, count - before.fetch(table, 0) ] if count > before.fetch(table, 0) }.to_h
        raise ActiveRecord::Rollback if dry_run
      end
      ActiveStorage::Blob.where(id: blob_ids).find_each(&:purge_later) unless dry_run

      Result.new(found: true, deleted:, retained:)
    rescue ActiveRecord::InvalidForeignKey
      raise ManualReviewRequired, "unexpected_reference"
    end

    private

    attr_reader :people

    People = Data.define(
      :users, :participants, :participant_events, :guardians, :guardian_links,
      :emails, :phones, :emergency_contacts, :invitations, :email_logs,
      :message_deliveries, :sms_logs, :tickets
    )

    def match
      emails = @subject.emails
      slack_id = @subject.slack_id
      identity_id = @subject.identity_id

      users = email_in(User, :email, emails)
      users = users.or(User.where(hack_club_account_id: identity_id)) if identity_id
      users = users.or(User.where(slack_user_id: slack_id)) if slack_id
      user_ids = users.pluck(:id)

      participants = email_in(Participant, :email, emails).or(Participant.where(user_id: user_ids))
      if slack_id
        participants = participants.or(Participant.where(slack_user_id: slack_id))
                                   .or(Participant.where(id: ParticipantEvent.where(slack_user_id: slack_id).select(:participant_id)))
      end
      participant_ids = participants.pluck(:id)
      participant_event_ids = ParticipantEvent.where(participant_id: participant_ids).pluck(:id)

      # guardians matched directly, plus anyone whose only reason to be here
      # is a child being erased: with the registration gone, their details
      # serve nothing
      matched_guardian_ids = email_in(Guardian, :email, emails).or(Guardian.where(user_id: user_ids)).pluck(:id)
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
      phones = phones.reject do |phone|
        Participant.where(phone:).where.not(id: participant_ids).exists? ||
          Guardian.where(phone:).where.not(id: guardian_ids).exists? ||
          EmergencyContact.where(phone:).where.not(id: EmergencyContact.where(participant_event_id: participant_event_ids).select(:id)).exists?
      end

      # a ticket filed against someone else stays, even from a shared number
      tickets = Ticket.where(subject_type: "Participant", subject_id: participant_ids)
                      .or(Ticket.where(subject_type: "Guardian", subject_id: guardian_ids))
      tickets = tickets.or(Ticket.where(subject_id: nil, phone_number: phones)) if phones.any?

      People.new(
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
        tickets: tickets.pluck(:id)
      )
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
      event_ids = ParticipantEvent.where(id: people.participant_events).pluck(:event_id) +
        GuardianParticipantEvent.where(id: people.guardian_links).joins(:participant_event).pluck("participant_events.event_id") +
        EmergencyContact.where(id: people.emergency_contacts).filter_map { |contact| (contact.participant_event || contact.guardian_participant_event&.participant_event)&.event_id }
      Event.where(id: event_ids.uniq).where("COALESCE(ends_at, starts_at) IS NULL OR COALESCE(ends_at, starts_at) > ?", @now).exists?
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
      signed = Consent.where(participant_event_id: people.participant_events).where.not(docuseal_envelope_id: nil).count
      retained << { type: "signed documents", count: signed, reason: DOCUSEAL_REASON } if signed.positive?

      synced = ParticipantEvent.where(id: people.participant_events).where.not(airtable_record_id: nil).count +
        GuardianParticipantEvent.where(id: people.guardian_links).where.not(airtable_record_id: nil).count +
        Accommodation.where(participant_event_id: people.participant_events).where.not(airtable_record_id: nil).count
      retained << { type: "airtable copies", count: synced, reason: AIRTABLE_REASON } if synced.positive?
      retained
    end

    def erase!
      ids = record_ids
      attachments = ActiveStorage::Attachment.where(record_id: ids)
      blob_ids = attachments.pluck(:blob_id)
      attachments.delete_all

      pes = people.participant_events
      users = people.users

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
      User.where(id: users).destroy_all

      PaperTrail::Version.where(item_id: ids).delete_all
      PaperTrail::Version.where(whodunnit: users).update_all(whodunnit: nil) if users.any?
      AuditLog.where(record_id: ids).delete_all
      AuditLog.where(actor_user_id: users).update_all(actor_user_id: nil) if users.any?

      blob_ids
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
      ids.concat(Consent.where(guardian_participant_event_id: people.guardian_links).pluck(:id))
      ids.concat(Note.where(ticket_id: people.tickets).pluck(:id))
      ids.uniq
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
