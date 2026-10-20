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
    STATUS_FIELD = "Status".freeze

    # "Action Taken" is free text ("Perma Ban", "Perma Ban, indefinite ban +
    # 1wk shush on appeal", "Indef Ban, Must verify identity", ...). A case
    # counts when any comma-separated part of it *starts* with perma/indef, so
    # "Warning, made clear that a permanent ban is next" does not, or is
    # exactly "ban" (telescreen's value), so "Temp Ban" and "Channel Ban" do not.
    PERMA_SEGMENT = /\A\s*(i.?ve\s+)?(perma|indef)/i
    BAN_SEGMENT = /\A\s*ban\s*\z/i
    EXCLUDED_STATUSES = %w[removed].freeze

    # Narrows the fetch server-side; qualifies? re-checks every row precisely.
    PREFILTER = %{OR(FIND("ban", LOWER({#{ACTION_FIELD}})), FIND("perma", LOWER({#{ACTION_FIELD}})), FIND("indef", LOWER({#{ACTION_FIELD}})))}.freeze

    # Refuse to revoke more than this share of active UCAT bans in one run
    # (beyond a small floor) unless forced: a renamed field or an emptied
    # table looks exactly like "everyone was unbanned".
    MAX_REVOKE_SHARE = 0.25
    MAX_REVOKE_FLOOR = 5

    class SafetyLimitExceeded < StandardError; end

    Result = Struct.new(:added, :reinstated, :revoked, :unchanged, :cases_without_identity, keyword_init: true)

    Person = Struct.new(:emails, :slack_ids, :case_ids, keyword_init: true) do
      # Stable while the person keeps any email; Slack-only people key on their ID.
      def key = emails.min || "slack:#{slack_ids.min}"
      def identifiers = emails.map { "email:#{_1}" } + slack_ids.map { "slack:#{_1}" }
    end

    def self.qualifies?(fields)
      return false if EXCLUDED_STATUSES.include?(fields[STATUS_FIELD].to_s.downcase)

      fields[ACTION_FIELD].to_s.split(",").any? { |segment| segment.match?(PERMA_SEGMENT) || segment.match?(BAN_SEGMENT) }
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
      result = Result.new(added: 0, reinstated: 0, revoked: 0, unchanged: 0, cases_without_identity: cases_without_identity)

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

    # => [[Person, ...], count of qualifying cases with neither email nor Slack ID]
    def fetch_people
      cases = []
      without_identity = 0
      offset = nil

      loop do
        page = @client.list_records(TABLE_ID, filter: PREFILTER, fields: [ ID_FIELD, EMAIL_FIELD, SLACK_FIELD, ACTION_FIELD, STATUS_FIELD ], page_size: 100, offset: offset)

        page.fetch("records").each do |record|
          fields = record.fetch("fields", {})
          next unless self.class.qualifies?(fields)

          identifiers = identifiers_from(fields)
          if identifiers.any?
            cases << { id: fields[ID_FIELD].presence || record["id"], identifiers: identifiers }
          else
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
          case_ids: group.map { _1[:id] }.uniq.sort
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
      reason = "UCAT ban (#{'case'.pluralize(person.case_ids.size)} #{person.case_ids.join(', ')})"

      if ban.nil?
        Ban.create!(source: :ucat, external_key: person.key, reason: reason,
          ban_emails: person.emails.map { BanEmail.new(email: _1) }, ban_slack_ids: person.slack_ids.map { BanSlackId.new(slack_id: _1) })
        result.added += 1
        return
      end

      reinstating = ban.revoked? && ban.revoked_by_id.nil?
      sync_identifiers(ban, person.emails, person.slack_ids)
      ban.assign_attributes(external_key: person.key, reason: reason)
      ban.revoked_at = nil if reinstating
      ban.save! if ban.changed?

      reinstating ? result.reinstated += 1 : result.unchanged += 1
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
