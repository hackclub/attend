module Identity
  # Joins existing users, participants and guardians up to Person rows, and
  # copies the addresses and numbers they carry into email_addresses and
  # phone_numbers. Behind `rake identity:backfill`.
  #
  # The rule throughout: only join rows when nothing about them disagrees. A
  # shared address is not a shared identity (a parent's inbox on two children's
  # registrations looks exactly like one person registering twice), so anything
  # ambiguous is left unattached and filed as an IdentityReview for a human.
  # Phone numbers are copied but never used to decide who anyone is.
  #
  # In order:
  #
  # 1. One person per user.
  # 2. Participants linked to an account (user_id) join that account's person.
  # 3. Remaining participants are grouped by normalised email: onto the person
  #    of the account holding that address, or one person per address, using
  #    DuplicateParticipantScan's clean / needs-review split for the group.
  # 4. Guardians get one person per normalised email when their names agree.
  #    They are never joined to an account's or participant's person by address
  #    alone; an overlap that looks like the same human is filed for review.
  #
  # Everything is planned in memory from light rows first, so a dry run issues
  # no writes at all and reports the same numbers an apply would. Rows that
  # already have a person are skipped, which is what makes a re-run safe.
  #
  # The report is counts only. It must stay that way: no addresses, names or
  # ids, since the output ends up in terminals and deploy logs.
  class Backfill
    UserRow = Struct.new(:id, :person_id, :email, :verified)
    ParticipantRow = Struct.new(:id, :person_id, :user_id, :email, :first_name, :last_name)
    GuardianRow = Struct.new(:id, :person_id, :email, :first_name, :last_name)
    Attachment = Struct.new(:id, :person_id, :verified)

    NORMALISED_EMAIL = Arel.sql("LOWER(BTRIM(email, E' \\t\\r\\n'))")

    attr_reader :report

    def initialize(apply: false, batch_size: 500, now: Time.current)
      @apply = apply
      @batch_size = batch_size
      @now = now
      @report = Hash.new { |sections, section| sections[section] = Hash.new { |kinds, kind| kinds[kind] = Hash.new(0) } }
      @new_people = Set.new
      @inserted_people = Set.new
      @attachments = { user: [], participant: [], guardian: [] }
      @reviews = {}
    end

    def call
      load_rows
      load_existing_contact_rows

      plan_users
      plan_linked_participants
      plan_participants_by_email
      plan_guardians

      attach_users
      attach_participants
      attach_guardians
      record_reviews

      count(:people, :mechanical, :created, @new_people.size)
      count(:reviews, :needs_review, :groups_recorded, @reviews.size)
      report
    end

    private

    attr_reader :apply, :batch_size, :now

    def count(section, kind, bucket, by = 1)
      report[section][kind][bucket] += by
    end

    # ---- Loading -----------------------------------------------------------

    def load_rows
      @users = {}
      User.in_batches(of: batch_size) do |batch|
        batch.pluck(:id, :person_id, NORMALISED_EMAIL, :hack_club_account_id).each do |id, person_id, email, account_id|
          @users[id] = UserRow.new(id, person_id, email, account_id.present?)
        end
      end

      @participants = []
      Participant.in_batches(of: batch_size) do |batch|
        batch.pluck(:id, :person_id, :user_id, NORMALISED_EMAIL, :legal_first_name, :legal_last_name).each do |values|
          @participants << ParticipantRow.new(*values)
        end
      end

      @guardians = []
      Guardian.in_batches(of: batch_size) do |batch|
        batch.pluck(:id, :person_id, NORMALISED_EMAIL, :legal_first_name, :legal_last_name).each do |values|
          @guardians << GuardianRow.new(*values)
        end
      end

      @users_by_email = @users.values.reject { |user| user.email.blank? }.group_by(&:email)
      @participants_by_email = @participants.reject { |participant| participant.email.blank? }.group_by(&:email)
      @participants_by_person = @participants.select(&:person_id).group_by(&:person_id)
    end

    # What is already in the new tables, so a re-run neither duplicates a row
    # nor counts one it would not write.
    def load_existing_contact_rows
      @email_keys = Set.new
      @verified_owner = {}
      @people_with_primary = Set.new
      EmailAddress.in_batches(of: batch_size) do |batch|
        batch.pluck(:person_id, :address, :verified_at, :primary).each do |person_id, address, verified_at, primary|
          @email_keys << [ person_id, address ]
          @verified_owner[address] = person_id if verified_at
          @people_with_primary << person_id if primary
        end
      end
      @phone_keys = Set.new
    end

    # ---- Planning ----------------------------------------------------------

    def new_person
      SecureRandom.uuid.tap { |id| @new_people << id }
    end

    def plan_attach(kind, row, person_id, verified: false)
      row.person_id = person_id
      (@participants_by_person[person_id] ||= []) << row if kind == :participant
      @attachments[kind] << Attachment.new(row.id, person_id, verified)
    end

    def plan_review(category, key:, reasons:, user_ids: [], participant_ids: [], guardian_ids: [])
      fingerprint = IdentityReview.fingerprint_for(category, key)
      @reviews[fingerprint] = {
        category: category, reasons: reasons.uniq.sort,
        user_ids: user_ids.uniq.sort, participant_ids: participant_ids.uniq.sort, guardian_ids: guardian_ids.uniq.sort
      }
    end

    def plan_users
      @users.each_value do |user|
        if user.person_id
          count(:users, :skipped, :already_attached)
        else
          plan_attach(:user, user, new_person, verified: user.verified)
          count(:users, :mechanical, :person_per_account)
        end
      end
    end

    # A user can have several participant rows pointing at it (user_id is not
    # unique). They join the account's person only when they agree with each
    # other; an account that somehow holds two different people is not ours to
    # untangle.
    def plan_linked_participants
      @participants.select(&:user_id).group_by(&:user_id).each do |user_id, group|
        candidates = group.reject(&:person_id)
        next count(:participants, :skipped, :already_attached, group.size) if candidates.empty?

        count(:participants, :skipped, :already_attached, group.size - candidates.size)
        person_id = @users.fetch(user_id).person_id
        reasons = participant_flags((group + @participants_by_person.fetch(person_id, [])).uniq)
        reasons << "rows already belong to different people" if group.filter_map(&:person_id).any? { |id| id != person_id }

        if reasons.any?
          plan_review("linked_participants", key: user_id, reasons: reasons,
            user_ids: [ user_id ], participant_ids: group.map(&:id))
          count(:participants, :needs_review, :linked_account_rows_disagree, candidates.size)
        else
          candidates.each { |participant| plan_attach(:participant, participant, person_id) }
          count(:participants, :mechanical, :linked_account, candidates.size)
        end
      end
    end

    def plan_participants_by_email
      unlinked = @participants.reject(&:user_id)
      count(:participants, :skipped, :already_attached, unlinked.count(&:person_id))

      # No address to group on: each row can only be its own person.
      unlinked.select { |participant| participant.email.blank? && participant.person_id.nil? }.each do |participant|
        plan_attach(:participant, participant, new_person)
        count(:participants, :mechanical, :single)
      end

      @participants_by_email.each do |email, group|
        candidates = group.select { |participant| participant.user_id.nil? && participant.person_id.nil? }
        next if candidates.empty?

        plan_participant_group(email, group, candidates)
      end
    end

    def plan_participant_group(email, group, candidates)
      accounts = @users_by_email.fetch(email, [])
      people = (accounts.map(&:person_id) + group.filter_map(&:person_id)).uniq

      # Whoever these rows would join has to agree with them too: an account
      # found by address may already hold a participant under another address.
      reasons = participant_flags((group + people.flat_map { |id| @participants_by_person.fetch(id, []) }).uniq)
      reasons << "more than one account at this address" if accounts.size > 1
      reasons << "rows already belong to different people" if people.size > 1
      # A linked row with no person was itself held back in step 2.
      reasons << "a linked row is awaiting review" if group.any? { |participant| participant.user_id && participant.person_id.nil? }

      if reasons.any?
        category = accounts.any? ? "participant_account_email" : "participant_duplicates"
        plan_review(category, key: email, reasons: reasons,
          user_ids: accounts.map(&:id), participant_ids: group.map(&:id))
        bucket = accounts.any? ? :email_matches_account_flagged : :same_email_flagged
        return count(:participants, :needs_review, bucket, candidates.size)
      end

      person_id = people.first || new_person
      candidates.each { |participant| plan_attach(:participant, participant, person_id) }
      bucket = if accounts.any? then :email_matches_account
      elsif group.size > 1 then :same_email_clean
      else :single
      end
      count(:participants, :mechanical, bucket, candidates.size)
    end

    # DuplicateParticipantScan's flags for rows sharing an address or an
    # account. The public-profile flag is dropped: it protects a merge from
    # deleting a profile, and nothing is merged or deleted here.
    def participant_flags(group)
      return [] if group.size < 2

      rows = Participant.where(id: group.map(&:id)).order(:created_at).to_a
      DuplicateParticipantScan.new.group_for(nil, rows).flags - [ DuplicateParticipantScan::PUBLIC_PROFILE_FLAG ]
    end

    def plan_guardians
      count(:guardians, :skipped, :already_attached, @guardians.count(&:person_id))

      @guardians.select { |guardian| guardian.email.blank? && guardian.person_id.nil? }.each do |guardian|
        plan_attach(:guardian, guardian, new_person)
        count(:guardians, :mechanical, :single)
      end

      @guardians.reject { |guardian| guardian.email.blank? }.group_by(&:email).each do |email, group|
        candidates = group.reject(&:person_id)
        next if candidates.empty?

        plan_guardian_group(email, group, candidates)
      end
    end

    def plan_guardian_group(email, group, candidates)
      people = group.filter_map(&:person_id).uniq
      reasons = []
      reasons << "name mismatch" unless NameMatch.agree?(group.map { |guardian| [ guardian.first_name, guardian.last_name ] })
      reasons << "rows already belong to different people" if people.size > 1

      if reasons.any?
        plan_review("guardian_duplicates", key: email, reasons: reasons, guardian_ids: group.map(&:id))
        return count(:guardians, :needs_review, :same_email_flagged, candidates.size)
      end

      person_id = people.first || new_person
      candidates.each { |guardian| plan_attach(:guardian, guardian, person_id) }
      count(:guardians, :mechanical, group.size > 1 ? :same_email_names_agree : :single, candidates.size)

      plan_guardian_overlap(email, group, candidates)
    end

    # The guardian keeps a person of their own either way. Sharing an address
    # with an account, or with a participant of the same name, may mean the
    # same human (a parent who also attends or staffs) or may not (a child
    # using a parent's inbox): that call is a person's to make.
    def plan_guardian_overlap(email, group, candidates)
      accounts = @users_by_email.fetch(email, [])
      namesakes = @participants_by_email.fetch(email, []).select do |participant|
        NameMatch.agree?([ [ group.first.first_name, group.first.last_name ], [ participant.first_name, participant.last_name ] ])
      end
      return if accounts.empty? && namesakes.empty?

      reasons = []
      reasons << "address belongs to an account" if accounts.any?
      reasons << "name matches a participant at this address" if namesakes.any?
      plan_review("guardian_overlap", key: email, reasons: reasons, guardian_ids: group.map(&:id),
        user_ids: accounts.map(&:id), participant_ids: namesakes.map(&:id))
      count(:guardians, :needs_review, :possible_same_person_kept_separate, candidates.size)
    end

    # ---- Writing -----------------------------------------------------------

    def attach_users
      each_batch(:user, User.includes(:training_profile)) do |user, attachment|
        add_email(attachment.person_id, user.email, source: "user", verified: attachment.verified, user_id: user.id)
        add_phone(attachment.person_id, source: "user") { user.phone_number }
        add_phone(attachment.person_id, source: "training_profile") { user.training_profile&.phone_number }
      end
    end

    def attach_participants
      each_batch(:participant, Participant.all) do |participant, attachment|
        add_email(attachment.person_id, participant.email, source: "participant")
        add_phone(attachment.person_id, source: "participant") { participant.phone }
      end
    end

    def attach_guardians
      each_batch(:guardian, Guardian.all) do |guardian, attachment|
        add_email(attachment.person_id, guardian.email, source: "guardian")
        add_phone(attachment.person_id, source: "guardian") { guardian.phone }
      end
    end

    # One transaction per batch, holding the people a batch needs, the
    # person_id on each row and its contact rows together: an interrupted run
    # leaves whole batches behind, never a person nothing points at.
    def each_batch(kind, scope)
      @attachments[kind].each_slice(batch_size) do |slice|
        records = scope.where(id: slice.map(&:id)).index_by(&:id)
        in_transaction do
          insert_people(slice.map(&:person_id))
          slice.each do |attachment|
            record = records[attachment.id]
            # Deleted, or attached by someone else, since the plan was made.
            next if record.nil? || record.person_id.present?

            # update_all: no validations, callbacks, versions or updated_at.
            # Legacy rows fail today's validations, and a participant's
            # callbacks would fan out wallet pass updates.
            record.class.where(id: record.id, person_id: nil).update_all(person_id: attachment.person_id) if apply
            yield record, attachment
          end
        end
      end
    end

    def in_transaction(&block)
      apply ? ActiveRecord::Base.transaction(&block) : yield
    end

    def insert_people(person_ids)
      fresh = person_ids.uniq.select { |id| @new_people.include?(id) && @inserted_people.add?(id) }
      return if fresh.empty? || !apply

      Person.insert_all(fresh.map { |id| { id: id, created_at: now, updated_at: now } })
    end

    def add_email(person_id, raw, source:, verified: false, user_id: nil)
      address = EmailAddress.normalize(raw)
      return if address.blank?
      return count(:email_addresses, :skipped, :not_an_address) unless address.match?(URI::MailTo::EMAIL_REGEXP)
      return unless @email_keys.add?([ person_id, address ])

      # Someone else has already proven this address. Keep ours as unverified
      # and let a person work out which account is the real owner.
      if verified && @verified_owner.key?(address) && @verified_owner[address] != person_id
        verified = false
        plan_review("verified_email_conflict", key: address, reasons: [ "address already verified for another person" ],
          user_ids: [ user_id ].compact)
        count(:email_addresses, :needs_review, :verified_for_another_person)
      end
      @verified_owner[address] = person_id if verified
      primary = @people_with_primary.add?(person_id).present?

      count(:email_addresses, :mechanical, verified ? :verified : :unverified)
      return unless apply

      EmailAddress.create!(person_id: person_id, address: address, source: source,
        verified_at: (now if verified), primary: primary)
    end

    # Takes a block so a value that will not decrypt costs us that one number,
    # not the run.
    def add_phone(person_id, source:)
      raw = begin
        yield
      rescue ActiveRecord::Encryption::Errors::Base
        return count(:phone_numbers, :skipped, :unreadable)
      end
      return if raw.blank?

      number = PhoneNormalizer.normalize(raw)
      return count(:phone_numbers, :skipped, :not_dialable) if number.nil?
      return unless @phone_keys.add?([ person_id, number ])
      return if !@new_people.include?(person_id) && PhoneNumber.exists?(person_id: person_id, number: number)

      count(:phone_numbers, :mechanical, :created)
      return unless apply

      PhoneNumber.create!(person_id: person_id, number: number, source: source)
    end

    def record_reviews
      return unless apply

      @reviews.each_slice(batch_size) do |slice|
        ActiveRecord::Base.transaction do
          slice.each do |fingerprint, attributes|
            IdentityReview.find_or_initialize_by(fingerprint: fingerprint).update!(attributes)
          end
        end
      end
    end
  end
end
