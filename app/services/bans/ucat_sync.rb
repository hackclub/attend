module Bans
  # Mirrors bans from the UCAT conduct cases base into the ban list.
  #
  # Cases are grouped into people by shared email or Slack ID (one person's
  # cases may carry an email, a Slack ID or both), and each person becomes one
  # Ban with source "ucat" holding all their identifiers. A person whose last
  # qualifying case goes away (action changed, case marked removed, row
  # deleted) has their ban revoked; if they come back the same row is
  # reinstated, so history stays on one record.
  #
  # A UCAT ban an admin revoked by hand (revoked_by set) is left alone: the
  # sync never overrides a human decision. Manual bans are never touched; a
  # synced ban keeps its own copy of identifiers that also sit on one.
  class UcatSync
    BASE_ID = "appvV4A3BuC7ttTEP".freeze
    TABLE_ID = "tblYd0CsHO4PGkdwF".freeze

    ID_FIELD = "ID".freeze
    EMAIL_FIELD = "Subject Email".freeze
    SLACK_FIELD = "Subject Slack ID".freeze
    ACTION_FIELD = "Action Taken".freeze
    UNTIL_FIELD = "Action Until".freeze
    STATUS_FIELD = "Status".freeze

    # "Action Taken" is free text ("Perma Ban", "Perma Ban, indefinite ban +
    # 1wk shush on appeal", "Indef Ban, Must verify identity", ...). A case
    # counts when any comma-separated part of it *starts* with perma/indef, so
    # "Warning, made clear that a permanent ban is next" does not, or is
    # exactly "ban" (telescreen's value), so "Temp Ban" and "Channel Ban" do not.
    PERMA_SEGMENT = /\A\s*(i.?ve\s+)?(perma|indef)/i
    BAN_SEGMENT = /\A\s*ban\s*\z/i
    # A temp ban only counts while it is still running: the case must say
    # when it ends ("Action Until") and that must be in the future. The ban
    # then expires in Attend at that moment. A temp ban without a date is
    # ignored rather than mirrored as indefinite, and one already served is
    # not mirrored as an expired row.
    TEMP_SEGMENT = /\A\s*temp(orary)?\s+ban/i
    # A perma ban (including telescreen's "ban") ends on its "Action Until"
    # date too, but only a strict ISO 8601 date counts, which is what
    # Airtable's date fields return. Anything else leaves the ban
    # indefinite, so a typo or a partial date like "March" never lifts it.
    ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/
    # A date-only end means "until that day is over" wherever the moderator
    # is, so it ends at the close of the day in the last time zone to finish
    # it (UTC-12) rather than in the app's zone.
    LAST_ZONE = "Etc/GMT+12".freeze
    EXCLUDED_STATUSES = %w[removed].freeze

    # Narrows the fetch server-side; qualifies? re-checks every row precisely.
    PREFILTER = %{OR(FIND("ban", LOWER({#{ACTION_FIELD}})), FIND("perma", LOWER({#{ACTION_FIELD}})), FIND("indef", LOWER({#{ACTION_FIELD}})))}.freeze

    # Refuse to revoke more than this share of active UCAT bans in one run
    # (beyond a small floor) unless forced: a renamed field or an emptied
    # table looks exactly like "everyone was unbanned".
    MAX_REVOKE_SHARE = 0.25
    MAX_REVOKE_FLOOR = 5

    class SafetyLimitExceeded < StandardError; end

    # expired: bans whose case end date has now passed (they lapse on their
    # own, so they show as Expired and never count toward the revoke limit).
    Result = Struct.new(:added, :reinstated, :revoked, :expired, :unchanged, :cases_without_identity, keyword_init: true)

    # cases: [{ id:, record_id:, until: }]. expires_at is nil while any case is
    # indefinite; otherwise the latest case end.
    Person = Struct.new(:emails, :slack_ids, :cases, keyword_init: true) do
      # Stable while the person keeps any email; Slack-only people key on their ID.
      def key = emails.min || "slack:#{slack_ids.min}"
      def identifiers = emails.map { "email:#{_1}" } + slack_ids.map { "slack:#{_1}" }
      def case_ids = cases.map { _1[:id] }
      def expires_at = cases.any? { _1[:until].nil? } ? nil : cases.map { _1[:until] }.max
      def in_force? = expires_at.nil? || expires_at.future?
    end

    # Whether the case is a ban at all, in force or already over: a perma
    # ban, or a temp ban with an end date. Cases whose date has passed still
    # count here so the sync can let a mirrored ban lapse (Expired) instead
    # of revoking it.
    def self.ban_case?(fields)
      return false if EXCLUDED_STATUSES.include?(fields[STATUS_FIELD].to_s.downcase)
      return true if perma?(fields)

      fields[ACTION_FIELD].to_s.split(",").any? { _1.match?(TEMP_SEGMENT) } && action_until(fields).present?
    end

    # Whether the case bans the person right now.
    def self.qualifies?(fields)
      return false unless ban_case?(fields)

      until_at = action_until(fields)
      until_at.nil? || until_at.future?
    end

    def self.perma?(fields)
      fields[ACTION_FIELD].to_s.split(",").any? { _1.match?(PERMA_SEGMENT) || _1.match?(BAN_SEGMENT) }
    end

    # When the ban ends, or nil for an indefinite perma ban (or a temp ban
    # whose date won't parse, which then isn't a ban case).
    def self.action_until(fields)
      raw = fields[UNTIL_FIELD].to_s.strip
      return nil if raw.blank?

      perma?(fields) ? parse_strict(raw) : parse_lenient(raw)
    end

    def self.parse_strict(raw)
      return end_of_day(Date.iso8601(raw)) if raw.match?(ISO_DATE)

      Time.iso8601(raw).in_time_zone
    rescue ArgumentError
      nil
    end

    def self.parse_lenient(raw)
      return parse_strict(raw) if raw.match?(ISO_DATE)

      Time.zone.parse(raw)
    rescue ArgumentError
      nil
    end

    def self.end_of_day(date)
      ActiveSupport::TimeZone[LAST_ZONE].local(date.year, date.month, date.day).end_of_day.in_time_zone
    end

    def initialize(client: nil, force: false)
      @client = client || Airtable::Client.new(
        api_key: ENV["UCAT_AIRTABLE_API_KEY"] || Rails.application.credentials.dig(:ucat, :airtable_api_key),
        base_id: BASE_ID
      )
      @force = force
    end

    def call
      people, cases_without_identity = fetch_people
      result = Result.new(added: 0, reinstated: 0, revoked: 0, expired: 0, unchanged: 0, cases_without_identity: cases_without_identity)

      existing = Ban.ucat.includes(:ban_emails, :ban_slack_ids).to_a
      by_identifier = existing.each_with_object({}) { |ban, index| identifiers_of(ban).each { index[_1] = ban } }
      by_key = existing.index_by(&:external_key)

      # Each existing ban goes to at most one person, so a person whose cases
      # split apart doesn't have one ban rewritten twice.
      matched = Set.new
      matches = people.map do |person|
        ban = ([ by_key[person.key] ] + person.identifiers.map { by_identifier[_1] }).compact.find { !matched.include?(_1) }
        matched << ban if ban
        [ person, ban ]
      end
      to_revoke = existing.select { |ban| ban.active? && !matched.include?(ban) }
      check_safety!(to_revoke.size, existing.count(&:active?))

      Ban.transaction do
        to_revoke.each do |ban|
          next if ban.revoked_by_id.present?

          ban.revoke!
          result.revoked += 1
        end

        matches.each { |person, ban| upsert(person, ban, result) }
      end

      result
    end

    private

    # => [[Person, ...], count of in-force cases with neither email nor Slack ID]
    def fetch_people
      cases = []
      without_identity = 0
      offset = nil

      loop do
        page = @client.list_records(TABLE_ID, filter: PREFILTER, fields: [ ID_FIELD, EMAIL_FIELD, SLACK_FIELD, ACTION_FIELD, UNTIL_FIELD, STATUS_FIELD ], page_size: 100, offset: offset)

        page.fetch("records").each do |record|
          fields = record.fetch("fields", {})
          next unless self.class.ban_case?(fields)

          identifiers = identifiers_from(fields)
          if identifiers.any?
            # Case IDs are strings throughout: Airtable hands an autonumber
            # back as an Integer, and a row with a blank ID falls back to its
            # record id, so mixed types would make the sort in
            # group_into_people raise.
            cases << { id: (fields[ID_FIELD].presence || record["id"]).to_s, record_id: record["id"], until: self.class.action_until(fields), identifiers: identifiers }
          elsif self.class.qualifies?(fields)
            without_identity += 1
          end
        end

        offset = page["offset"]
        break if offset.blank?
      end

      [ group_into_people(cases), without_identity ]
    end

    def identifiers_from(fields)
      email = fields[EMAIL_FIELD].to_s.strip.downcase
      slack_id = fields[SLACK_FIELD].to_s.strip.upcase

      [
        ("email:#{email}" if email.match?(URI::MailTo::EMAIL_REGEXP)),
        ("slack:#{slack_id}" if slack_id.match?(BanSlackId::FORMAT))
      ].compact
    end

    # Union-find over identifiers: cases sharing an email or Slack ID, directly
    # or through another case, belong to the same person.
    def group_into_people(cases)
      parent = {}
      find = ->(x) { parent[x] == x ? x : (parent[x] = find.(parent[x])) }
      cases.each do |c|
        c[:identifiers].each { parent[_1] ||= _1 }
        c[:identifiers].each_cons(2) { |a, b| parent[find.(a)] = find.(b) }
      end

      cases.group_by { find.(_1[:identifiers].first) }.values.map do |group|
        identifiers = group.flat_map { _1[:identifiers] }.uniq
        Person.new(
          emails: identifiers.filter_map { _1.delete_prefix("email:") if _1.start_with?("email:") },
          slack_ids: identifiers.filter_map { _1.delete_prefix("slack:") if _1.start_with?("slack:") },
          cases: group.uniq { _1[:id] }.sort_by { _1[:id] }.map { _1.slice(:id, :record_id, :until) }
        )
      end
    end

    def check_safety!(revoking, active)
      return if @force || revoking.zero?
      return if revoking < active && revoking <= [ MAX_REVOKE_FLOOR, (active * MAX_REVOKE_SHARE).floor ].max

      raise SafetyLimitExceeded,
        "UCAT sync would revoke #{revoking} of #{active} active bans; refusing. " \
        "Check the UCAT base, then run SyncUcatBansJob.perform_now(force: true) if this is intended."
    end

    def upsert(person, ban, result)
      attributes = {
        external_key: person.key,
        reason: "UCAT ban (#{'case'.pluralize(person.case_ids.size)} #{person.case_ids.join(', ')})",
        expires_at: person.expires_at,
        ucat_cases: person.cases.map { { "id" => _1[:id], "record_id" => _1[:record_id] } }
      }

      if ban.nil?
        # A ban that's already over isn't mirrored as an expired row.
        return unless person.in_force?

        Ban.create!(source: :ucat, **attributes,
          ban_emails: person.emails.map { BanEmail.new(email: _1) }, ban_slack_ids: person.slack_ids.map { BanSlackId.new(slack_id: _1) })
        result.added += 1
        return
      end

      # A person in force who wasn't banned before (revoked by an earlier
      # sync, or a temp ban that had run out before UCAT extended it) is a
      # reinstatement, and the run should say so rather than file it under
      # "unchanged". One whose cases have all ended keeps the row, now with
      # the passed end date, so it lapses as Expired rather than Revoked.
      was_active = ban.active?
      reinstating = person.in_force? && !was_active && ban.revoked_by_id.nil?
      sync_identifiers(ban, person.emails, person.slack_ids)
      ban.assign_attributes(attributes)
      ban.revoked_at = nil if reinstating
      ban.save! if ban.changed?

      if reinstating
        result.reinstated += 1
      elsif was_active && !ban.active?
        result.expired += 1
      else
        result.unchanged += 1
      end
    end

    def sync_identifiers(ban, emails, slack_ids)
      ban.ban_emails.reject { emails.include?(_1.email) }.each(&:destroy!)
      (emails - ban.ban_emails.map(&:email)).each { ban.ban_emails.create!(email: _1) }
      ban.ban_slack_ids.reject { slack_ids.include?(_1.slack_id) }.each(&:destroy!)
      (slack_ids - ban.ban_slack_ids.map(&:slack_id)).each { ban.ban_slack_ids.create!(slack_id: _1) }
      ban.ban_emails.reset
      ban.ban_slack_ids.reset
    end

    def identifiers_of(ban)
      ban.ban_emails.map { "email:#{_1.email.downcase}" } + ban.ban_slack_ids.map { "slack:#{_1.slack_id}" }
    end
  end
end
