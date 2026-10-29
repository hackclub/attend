# One-shot migration off Envoy, the standalone visa letter app that owned
# visas.hackclub.com before Attend took letters over. Run through
# lib/tasks/envoy_import.rake, which explains how.
#
# What comes across, in order:
# - Events. Each one in the event map is linked to the Attend event it names.
#   Every other one becomes a finished event in Attend that exists to hold its
#   letters: set up, in UTC, its letters switched off, and marked
#   `imported_from: "envoy"` so it doesn't count as an event Attend ran.
#   Either way it records its Envoy slug, which visas.hackclub.com's old
#   /events links use.
# - Letter templates, with their signatures. Bodies keep their blank-line
#   paragraphs; <strong>/<em> become the <b>/<i> the letter PDF understands.
# - Applications, keeping their ids, reference numbers and verification
#   codes, so printed letters still verify and emailed links still work.
#   Ones whose email was never verified are left behind. A sent letter's PDF
#   is copied from Envoy's bucket byte for byte, never regenerated.
# - Unclaimed invitations to apply, keeping their tokens.
# - Envoy's event owners and collaborators become event admins of the past
#   events the import creates, where Attend has an account with their email.
#   On a mapped event, Attend's own, that role would open every participant's
#   details to them, so they're only listed for someone to add by hand.
#
# Idempotent: anything already in Attend under the same id (or reference
# number, verification code or token) is left as it is, apart from attaching
# a letter or signature an earlier run couldn't copy.
class EnvoyImport
  STATUSES = {
    "pending_approval" => "pending",
    "approved" => "approved",
    "rejected" => "rejected",
    "letter_sent" => "letter_sent"
  }.freeze

  # Envoy's tables, read through the connection the rake task opens. Each
  # class needs a name: Active Record won't build an anonymous one.
  TABLES = {
    events: "events", admins: "admins", event_admins: "event_admins", templates: "letter_templates",
    applications: "visa_letter_applications", participants: "participants", invitations: "manual_invitations",
    attachments: "active_storage_attachments", blobs: "active_storage_blobs"
  }.freeze

  def self.source_tables(database_url)
    base = Class.new(ActiveRecord::Base) do
      self.abstract_class = true
      def self.name = "EnvoyRecord"
    end
    base.establish_connection(database_url)

    TABLES.to_h do |key, table|
      model = Class.new(base) do
        self.table_name = table
        self.inheritance_column = nil
      end
      model.define_singleton_method(:name) { "EnvoyRecord::#{table.classify}" }
      [ key, model ]
    end
  end

  # Envoy's Active Storage bucket on Cloudflare R2, read-only.
  class R2Storage
    VARIABLES = %w[ENVOY_R2_ENDPOINT ENVOY_R2_BUCKET ENVOY_R2_ACCESS_KEY_ID ENVOY_R2_SECRET_ACCESS_KEY].freeze

    def self.from_env(env = ENV)
      return if VARIABLES.any? { |name| env[name].blank? }

      new(endpoint: env["ENVOY_R2_ENDPOINT"], bucket: env["ENVOY_R2_BUCKET"],
        access_key_id: env["ENVOY_R2_ACCESS_KEY_ID"], secret_access_key: env["ENVOY_R2_SECRET_ACCESS_KEY"])
    end

    def initialize(endpoint:, bucket:, access_key_id:, secret_access_key:)
      require "aws-sdk-s3"
      @bucket = bucket
      @client = Aws::S3::Client.new(endpoint: endpoint, access_key_id: access_key_id,
        secret_access_key: secret_access_key, region: "auto")
    end

    def read(key)
      @client.get_object(bucket: @bucket, key: key).body.read
    end

    def exists?(key)
      @client.head_object(bucket: @bucket, key: key)
      true
    rescue Aws::S3::Errors::NotFound
      false
    end
  end

  attr_reader :counts, :notes, :unmatched_people

  # `event_map` is { envoy_slug => attend_slug }. `storage` reads Envoy's
  # files by blob key; without it, nothing that needs a file is written.
  def initialize(tables:, apply:, event_map: {}, storage: nil, out: $stdout, now: Time.current)
    @envoy = tables
    @apply = apply
    @event_map = event_map
    @storage = storage
    @out = out
    @now = now
    @counts = Hash.new(0)
    @notes = []
    @unmatched_people = []
  end

  def run
    import_events
    import_templates
    import_applications
    import_invitations
    import_people
    report
    self
  end

  # Envoy stored plain text that it ran through simple_format, with <strong>
  # and <em> where someone wanted emphasis.
  def self.template_body(body)
    body.to_s.gsub(/\r\n?/, "\n")
      .gsub(%r{<(/?)strong\b[^>]*>}i) { "<#{::Regexp.last_match(1)}b>" }
      .gsub(%r{<(/?)em\b[^>]*>}i) { "<#{::Regexp.last_match(1)}i>" }
  end

  private

  def apply? = @apply

  def import_events
    @attend_events = {}
    @envoy[:events].order(:created_at).each do |envoy_event|
      @attend_events[envoy_event.id] = if (attend_slug = @event_map[envoy_event.slug])
        link_event(envoy_event, attend_slug)
      else
        imported_event(envoy_event)
      end
    end

    unknown = @event_map.keys - @envoy[:events].pluck(:slug)
    unknown.each { |slug| @notes << "Event map: Envoy has no event #{slug}" }
  end

  def link_event(envoy_event, attend_slug)
    event = Event.find_by(slug: attend_slug)
    if event.nil?
      @notes << "Event map: Attend has no event #{attend_slug} (for Envoy's #{envoy_event.slug}); its applications are skipped"
      return
    end

    event.legacy_envoy_slug = envoy_event.slug
    if event.visa_letter_rejection_reasons_list.empty? && envoy_event.rejection_reason_templates.present?
      event.visa_letter_rejection_reasons = Array(envoy_event.rejection_reason_templates)
    end
    @counts[:events_linked] += 1
    say "event #{envoy_event.slug} -> #{event.slug} (linked)"
    event.save! if apply? && event.changed?
    event
  end

  def imported_event(envoy_event)
    existing = Event.find_by("config->>'legacy_envoy_slug' = ?", envoy_event.slug)
    if existing
      @counts[:events_existing] += 1
      return existing
    end

    event = Event.new(
      name: envoy_event.name,
      slug: free_slug(envoy_event.slug),
      venue_name: envoy_event.venue_name,
      location_address: envoy_event.venue_address,
      location_city: envoy_event.city,
      location_country: envoy_event.country,
      timezone: "UTC",
      starts_at: envoy_event.start_date.in_time_zone("UTC").beginning_of_day,
      ends_at: envoy_event.end_date.in_time_zone("UTC").end_of_day,
      setup_completed_at: envoy_event.created_at,
      support_email: hack_club_address(envoy_event.contact_email),
      created_at: envoy_event.created_at
    )
    event.visa_letters = "off"
    event.visa_letter_rejection_reasons = Array(envoy_event.rejection_reason_templates).presence
    event.legacy_envoy_slug = envoy_event.slug
    event.config["imported_from"] = "envoy"

    unless event.valid?
      @notes << "Event #{envoy_event.slug}: #{event.errors.full_messages.to_sentence}; its applications are skipped"
      return
    end
    if envoy_event.end_date >= @now.to_date
      @notes << "Event #{envoy_event.slug} hasn't ended (#{envoy_event.end_date}). If Attend runs it, map it with ENVOY_EVENT_MAP instead."
    end

    @counts[:events_created] += 1
    say "event #{envoy_event.slug} -> #{event.slug} (new, #{envoy_event.start_date} to #{envoy_event.end_date})"
    event.save! if apply?
    event
  end

  # Envoy's slug, unless Attend already uses it for another event.
  def free_slug(slug)
    return slug unless Event.exists?(slug: slug) || Event::RESERVED_SLUGS.include?(slug)

    candidate = "#{slug}-envoy"
    candidate = "#{slug}-envoy-#{SecureRandom.hex(2)}" while Event.exists?(slug: candidate)
    @notes << "Event #{slug}: Attend already uses that slug, so it's imported as #{candidate}. If Attend's event is the same one, map it with ENVOY_EVENT_MAP instead."
    candidate
  end

  # The support address is the sender on participant email, so only one of
  # Hack Club's own will do.
  def hack_club_address(email)
    email.to_s.strip.downcase.presence&.then { |address| address if Event::SUPPORT_EMAIL_FORMAT.match?(address) }
  end

  def import_templates
    @envoy[:templates].order(:created_at).each do |envoy_template|
      template = VisaLetterTemplate.find_by(id: envoy_template.id)
      if template
        @counts[:templates_existing] += 1
        attach_signature(template, envoy_template) unless template.signature_image.attached?
        next
      end

      event = nil
      if envoy_template.event_id
        event = @attend_events[envoy_template.event_id]
        next @notes << "Template #{envoy_template.name}: its event wasn't imported" if event.nil?
      end

      template = VisaLetterTemplate.new(
        id: envoy_template.id, event: event, name: envoy_template.name,
        body: self.class.template_body(envoy_template.body),
        signatory_name: envoy_template.signatory_name, signatory_title: envoy_template.signatory_title,
        active: envoy_template.active, is_default: envoy_template.is_default && event.nil?,
        created_at: envoy_template.created_at, updated_at: envoy_template.updated_at
      )
      if template.is_default? && VisaLetterTemplate.where(is_default: true, event_id: nil).exists?
        template.is_default = false
        @notes << "Template #{template.name}: Attend already has a default, so it's imported as an ordinary one"
      end
      if attachment_blob("LetterTemplate", envoy_template.id, "letterhead_image")
        @notes << "Template #{template.name}: its letterhead image isn't carried over (Attend's letters print their own)"
      end
      next @notes << "Template #{template.name}: #{template.errors.full_messages.to_sentence}" unless template.valid?

      @counts[:templates] += 1
      say "template #{template.name}#{" (#{event.slug})" if event}"
      template.save! if apply?
      attach_signature(template, envoy_template)
    end
  end

  def attach_signature(template, envoy_template)
    blob = attachment_blob("LetterTemplate", envoy_template.id, "signature_image")
    return if blob.nil?

    @counts[:signatures] += 1
    copy_file(blob, template.signature_image, "Template #{template.name}'s signature")
  end

  def import_applications
    rows = @envoy[:applications].order(:created_at).to_a
    @counts[:applications_unverified] = rows.count { |row| row.status == "pending_verification" }
    rows = rows.reject { |row| row.status == "pending_verification" }
    participants = @envoy[:participants].where(id: rows.map(&:participant_id)).index_by(&:id)
    envoy_events = @envoy[:events].all.index_by(&:id)
    reviewers = @envoy[:admins].where(id: rows.filter_map(&:reviewed_by_id)).pluck(:id, :email).to_h

    rows.each do |row|
      import_application(row, participants.fetch(row.participant_id), envoy_events.fetch(row.event_id), reviewers[row.reviewed_by_id])
    end
  end

  def import_application(row, participant, envoy_event, reviewer_email)
    reference = row.reference_number
    existing = VisaLetterApplication.find_by(id: row.id)
    if existing
      @counts[:applications_existing] += 1
      copy_letter(existing, row) if existing.letter_sent? && !existing.letter_pdf.attached?
      return
    end

    event = @attend_events[row.event_id]
    return @notes << "Application #{reference}: its event wasn't imported" if event.nil?
    status = STATUSES[row.status]
    return @notes << "Application #{reference}: unknown status #{row.status}" if status.nil?
    if VisaLetterApplication.exists?(reference_number: reference) ||
        (row.verification_code.present? && VisaLetterApplication.exists?(verification_code: row.verification_code))
      return @notes << "Application #{reference}: Attend already has another application with its reference number or verification code"
    end

    email = participant.email.to_s.strip.downcase
    application = VisaLetterApplication.new(
      id: row.id, event: event, imported_at: @now, status: status,
      user: applicant_account(email, event), reviewed_by: user_with_email(reviewer_email),
      full_name: participant.full_name, email: email, date_of_birth: participant.date_of_birth,
      nationality: participant.country_of_birth, place_of_birth: participant.place_of_birth,
      phone: participant.phone_number, address: participant.full_street_address,
      reference_number: reference, verification_code: row.verification_code.presence,
      rejection_type: (row.rejection_type.presence if status == "rejected"), rejection_reason: row.rejection_reason,
      admin_notes: row.admin_notes, submitted_at: row.submitted_at || row.created_at, reviewed_at: row.reviewed_at,
      letter_sent_at: row.letter_sent_at, created_at: row.created_at, updated_at: row.updated_at
    )
    if status == "letter_sent"
      # What Envoy printed: the event as it stands, and the day it rendered
      # the letter (Envoy ran in UTC).
      rendered_at = row.letter_generated_at || row.letter_sent_at || row.updated_at
      application.assign_attributes(
        letter_event_name: envoy_event.name, letter_venue: envoy_event.venue_name,
        letter_address: envoy_event.venue_address, letter_city: envoy_event.city, letter_country: envoy_event.country,
        letter_starts_on: envoy_event.start_date, letter_ends_on: envoy_event.end_date,
        letter_issued_on: rendered_at.utc.to_date
      )
      # Envoy's participant is shared between their applications, so a later
      # one can change it after this letter printed. /verify shows these
      # details and they freeze once sent, so someone checks them first.
      if participant.updated_at > rendered_at
        @notes << "Application #{reference}: Envoy's participant changed after its letter was generated, so check the name and details against the PDF"
      end
    end
    if row.pending_participant_attributes.present?
      @notes << "Application #{reference}: Envoy held details for it that it hadn't applied yet (pending_participant_attributes); they aren't carried over"
    end
    @counts[:reviewers_unmatched] += 1 if reviewer_email.present? && application.reviewed_by.nil?
    return @notes << "Application #{reference}: #{application.errors.full_messages.to_sentence}" unless application.valid?

    @counts[:"applications_#{status}"] += 1
    @counts[:applications_linked] += 1 if application.user
    @counts[:approved_without_letter] += 1 if status == "approved"
    application.save! if apply?
    copy_letter(application, row) if application.letter_sent?
  end

  # Only a Hack Club account, as when someone claims an import by signing in,
  # and only one application per account per event.
  def applicant_account(email, event)
    user = User.where("LOWER(email) = ?", email).where.not(hack_club_account_id: nil).first
    return if user.nil?
    return if event.persisted? && VisaLetterApplication.exists?(event_id: event.id, user_id: user.id)

    user
  end

  def user_with_email(email)
    User.find_by("LOWER(email) = ?", email.to_s.strip.downcase) if email.present?
  end

  def copy_letter(application, row)
    blob = attachment_blob("VisaLetterApplication", row.id, "letter_pdf")
    return @notes << "Application #{application.reference_number}: Envoy has no letter PDF for it" if blob.nil?

    @counts[:letters] += 1
    copy_file(blob, application.letter_pdf, "Application #{application.reference_number}'s letter")
  end

  def attachment_blob(record_type, record_id, name)
    attachment = @envoy[:attachments].find_by(record_type: record_type, record_id: record_id, name: name)
    attachment && @envoy[:blobs].find_by(id: attachment.blob_id)
  end

  # Byte for byte: Envoy's checksum has to match what was downloaded. A dry
  # run only checks the file is there.
  def copy_file(blob, attachment, label)
    if @storage.nil?
      @notes << "#{label}: not copied, since Envoy's bucket isn't configured (ENVOY_R2_*)" if apply?
      return
    end
    unless apply?
      @notes << "#{label}: missing from Envoy's bucket" unless @storage.exists?(blob.key)
      return
    end

    bytes = @storage.read(blob.key)
    if blob.checksum.present? && Digest::MD5.base64digest(bytes) != blob.checksum
      return @notes << "#{label}: not copied, since the file from Envoy's bucket doesn't match its checksum"
    end

    return if attachment.attach(io: StringIO.new(bytes), filename: blob.filename, content_type: blob.content_type, identify: false)

    @notes << "#{label}: not copied (#{attachment.record.errors.full_messages.to_sentence})"
  rescue => e
    @notes << "#{label}: not copied (#{e.class}: #{e.message})"
  end

  def import_invitations
    invitations = @envoy[:invitations].where(claimed_at: nil).order(:created_at).to_a
    issuers = @envoy[:admins].where(id: invitations.map(&:admin_id)).pluck(:id, :email).to_h

    invitations.each do |row|
      if VisaLetterInvitation.where(id: row.id).or(VisaLetterInvitation.where(token: row.token)).exists?
        @counts[:invitations_existing] += 1
        next
      end
      event = @attend_events[row.event_id]
      next if event.nil?

      invitation = VisaLetterInvitation.new(id: row.id, event: event, email: row.email, token: row.token,
        issued_by: user_with_email(issuers[row.admin_id]), created_at: row.created_at, updated_at: row.updated_at)
      next @notes << "Invitation for #{event.slug}: #{invitation.errors.full_messages.to_sentence}" unless invitation.valid?

      @counts[:invitations] += 1
      invitation.save! if apply?
    end
  end

  # Envoy's owner and collaborators for each event. Only the past events the
  # import creates get them as event admins: on Attend's own (mapped) events
  # that role reaches every participant's details, so it's left to a person.
  def import_people
    admins = @envoy[:admins].pluck(:id, :email).to_h
    @envoy[:events].order(:created_at).each do |envoy_event|
      event = @attend_events[envoy_event.id]
      next if event.nil?

      admin_ids = [ envoy_event.admin_id, *@envoy[:event_admins].where(event_id: envoy_event.id).pluck(:admin_id) ].uniq
      admin_ids.filter_map { |id| admins[id] }.each do |email|
        user = user_with_email(email)
        next @unmatched_people << "#{email} (#{envoy_event.slug})" if user.nil?
        next @counts[:people_global_admin] += 1 if user.global_admin?

        existing = event.persisted? && EventRoleAssignment.find_by(user: user, event: event)
        if existing
          @counts[:people_existing] += 1
          @notes << "#{email} is already #{existing.role.humanize.downcase} on #{event.slug}, so is left as that" unless existing.event_admin?
          next
        end
        unless event.imported?
          @counts[:people_not_granted] += 1
          @notes << "#{email} reviewed letters for #{envoy_event.slug} in Envoy, but isn't made an event admin of #{event.slug}, Attend's own event. Add them by hand if they should be."
          next
        end

        @counts[:people] += 1
        say "event admin #{email} on #{event.slug}"
        EventRoleAssignment.create!(user: user, event: event, role: :event_admin) if apply?
      end
    end
  end

  def report
    verb = apply? ? "Imported" : "Would import"
    say ""
    say "Events: #{@counts[:events_linked]} linked to Attend's, #{verb.downcase} #{@counts[:events_created]} as past events, #{@counts[:events_existing]} already imported."
    say "Templates: #{verb.downcase} #{@counts[:templates]}, #{@counts[:templates_existing]} already imported, #{@counts[:signatures]} signature(s) to copy."
    application_counts = STATUSES.values.map { |status| "#{@counts[:"applications_#{status}"]} #{status.humanize.downcase}" }.join(", ")
    say "Applications: #{verb.downcase} #{application_counts}; #{@counts[:applications_existing]} already imported; " \
      "#{@counts[:applications_unverified]} never verified, left behind."
    say "  #{@counts[:applications_linked]} linked to a Hack Club account; #{@counts[:letters]} letter PDF(s) to copy; " \
      "#{@counts[:reviewers_unmatched]} reviewed by someone with no Attend account."
    if @counts[:approved_without_letter].positive?
      say "  #{@counts[:approved_without_letter]} approved in Envoy without a letter: Attend won't generate one for them, so check them by hand."
    end
    say "Invitations: #{verb.downcase} #{@counts[:invitations]} unclaimed, #{@counts[:invitations_existing]} already imported."
    say "People: #{verb.downcase} #{@counts[:people]} event admin(s) on imported events; #{@counts[:people_existing]} already on the event, " \
      "#{@counts[:people_global_admin]} global admin(s) skipped, #{@counts[:people_not_granted]} on Attend's own events left to add by hand (see notes)."

    if @unmatched_people.any?
      say "\nNo Attend account for #{@unmatched_people.size} of Envoy's event admins:"
      @unmatched_people.each { |line| say "  #{line}" }
    end
    if @notes.any?
      say "\nNotes (#{@notes.size}):"
      @notes.each { |line| say "  #{line}" }
    end
    say "\nDry run — re-run with APPLY=1 to write changes." unless apply?
  end

  def say(line)
    @out.puts(line)
  end
end
