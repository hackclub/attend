module Rooming
  # Puts people on an eligible-only stay's roster. Shared by the admin roster
  # page (by hand, pasted emails/CSV, a group) and the API a shop calls when
  # someone buys the night, so they all upsert the same way: adding someone
  # who's already listed updates their reason rather than failing.
  class Roster
    EMAIL_PATTERN = /[^\s,;<>"']+@[^\s,;<>"']+\.[^\s,;<>"']+/

    Result = Struct.new(:added, :updated, :not_registered, keyword_init: true) do
      def entries
        added + updated
      end
    end

    def initialize(rooming_context, added_by: nil)
      @rooming_context = rooming_context
      @event = rooming_context.event
      @added_by = added_by
    end

    # Returns [entry, created]. Blank option/reference/notes leave what's
    # already recorded alone, so a re-sent shop webhook can't wipe a reason an
    # organizer set.
    def add(participant_event, source:, option: nil, external_reference: nil, notes: nil)
      entry = @rooming_context.roster_entries.find_or_initialize_by(participant_event: participant_event)
      created = entry.new_record?

      entry.source = source if created
      entry.added_by_user ||= @added_by
      entry.eligibility_option = option if option
      entry.external_reference = external_reference if external_reference.present?
      entry.notes = notes if notes.present?
      entry.save!

      [ entry, created ]
    rescue ActiveRecord::RecordNotUnique
      # Two requests for the same person raced; the other one created it.
      retry
    end

    def add_participant_events(participant_events, source:, option: nil)
      result = Result.new(added: [], updated: [], not_registered: [])

      RoomingRosterEntry.transaction do
        participant_events.each do |participant_event|
          entry, created = add(participant_event, source: source, option: option)
          (created ? result.added : result.updated) << entry
        end
      end

      result
    end

    # Takes anything with email addresses in it: one per line, a pasted
    # spreadsheet column, or a whole CSV export. Every address is matched
    # against this event's registrations; the ones that aren't registered come
    # back so the organizer can chase them.
    def add_emails(text, option: nil)
      emails = text.to_s.scan(EMAIL_PATTERN).map { |email| email.downcase.delete_suffix(".") }.uniq
      by_email = registrations_by_email(emails)

      result = add_participant_events(by_email.values, source: :csv, option: option)
      result.not_registered = emails - by_email.keys
      result
    end

    def registration_for_email(email)
      registrations_by_email([ email.to_s.strip.downcase ]).values.first
    end

    private

    # Participant emails aren't stored lowercased, so compare case-blind.
    def registrations_by_email(emails)
      return {} if emails.empty?

      @event.participant_events
        .joins(:participant)
        .where("LOWER(participants.email) IN (?)", emails)
        .includes(:participant)
        .index_by { |participant_event| participant_event.participant.email.downcase }
    end
  end
end
