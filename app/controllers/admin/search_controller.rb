module Admin
  class SearchController < BaseController
    def index
      query = params[:q].to_s.strip
      results = {}

      if query.present?
        results[:participants] = search_participants_fuzzy(query)
        results[:guardians] = search_guardians(query)
        results[:events] = search_events(query)
        results[:users] = search_users(query) if current_user.global_admin?
      end

      render json: results
    end

    private

    def search_participants_fuzzy(query)
      scope = if current_user.global_admin?
        Participant.all
      else
        Participant.joins(:participant_events)
                   .where(participant_events: { event_id: current_user.assigned_event_ids })
                   .distinct
      end

      exact_matches = if (phone = phone_query_e164(query))
        scope.where(phone: phone).limit(10).to_a
      elsif (slack_id = slack_id_query(query))
        scope.where("UPPER(participants.slack_user_id) = ?", slack_id).limit(10).to_a
      else
        []
      end

      quoted_query = Participant.connection.quote(query)
      sanitized_like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"

      participants = scope
        .select(
          "participants.*",
          "GREATEST(
            COALESCE(similarity(unaccent(legal_first_name), unaccent(#{quoted_query})), 0),
            COALESCE(similarity(unaccent(legal_last_name), unaccent(#{quoted_query})), 0),
            COALESCE(similarity(email, #{quoted_query}), 0),
            COALESCE(similarity(unaccent(preferred_name), unaccent(#{quoted_query})), 0),
            COALESCE(similarity(unaccent(CONCAT(legal_first_name, ' ', legal_last_name)), unaccent(#{quoted_query})), 0)
          ) AS relevance"
        )
        .where(
          "unaccent(legal_first_name) % unaccent(:q) OR unaccent(legal_last_name) % unaccent(:q) " \
          "OR email % :q OR unaccent(preferred_name) % unaccent(:q) " \
          "OR unaccent(CONCAT(legal_first_name, ' ', legal_last_name)) % unaccent(:q) " \
          "OR unaccent(legal_first_name) ILIKE unaccent(:like) OR unaccent(legal_last_name) ILIKE unaccent(:like) " \
          "OR email ILIKE :like",
          q: query,
          like: sanitized_like
        )
        .order("relevance DESC")
        .limit(10)

      visible_event_ids = current_user.global_admin? ? nil : current_user.assigned_event_ids

      participants = (exact_matches + participants.to_a).uniq(&:id).first(10)

      participants.flat_map do |p|
        pe_scope = p.participant_events.includes(:event)
        pe_scope = pe_scope.where(event_id: visible_event_ids) if visible_event_ids

        pe_scope.map do |pe|
          next unless pe.event

          {
            id: pe.id,
            name: p.full_name,
            email: p.email,
            event_name: pe.event.name,
            url: admin_event_participant_path(pe.event, pe)
          }
        end
      end.compact.first(10)
    end

    # Parents and guardians by email or name, one row per child registration so
    # the result opens the participant they're attached to. Guardian contact
    # details are hidden from PII-restricted roles, so those events are left
    # out entirely rather than matching on an email the role can't see.
    def search_guardians(query)
      return [] if query.length < 3

      event_ids = guardian_searchable_event_ids
      return [] if event_ids == []

      like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      scope = GuardianParticipantEvent
        .joins(:guardian, :participant_event)
        .where(
          "guardians.email ILIKE :like OR unaccent(guardians.legal_first_name) ILIKE unaccent(:like) " \
          "OR unaccent(guardians.legal_last_name) ILIKE unaccent(:like) " \
          "OR unaccent(CONCAT(guardians.legal_first_name, ' ', guardians.legal_last_name)) ILIKE unaccent(:like)",
          like: like
        )
      scope = scope.where(participant_events: { event_id: event_ids }) if event_ids

      scope
        .includes(:guardian, participant_event: [ :participant, :event ])
        .order("guardians.email")
        .limit(10)
        .filter_map do |link|
          pe = link.participant_event
          next unless pe.event && pe.participant

          {
            id: link.id,
            name: link.guardian.full_name,
            email: link.guardian.email,
            participant_name: pe.participant.full_name,
            event_name: pe.event.name,
            url: admin_event_participant_path(pe.event, pe)
          }
        end
    end

    # nil means every event (global admins).
    def guardian_searchable_event_ids
      return nil if current_user.global_admin?

      unrestricted = current_user.event_role_assignments
        .where.not(role: EventRoleAssignment::PII_RESTRICTED_ROLES)
        .pluck(:event_id)
      (unrestricted + (current_user.assigned_event_ids & current_user.series_event_ids)).uniq
    end

    # `phone` is encrypted deterministically, so it can't participate in the
    # similarity/ILIKE SQL above — only an exact e164 match will hit.
    def phone_query_e164(query)
      return unless query.delete(" ().-").match?(/\A\+?\d{7,15}\z/)

      PhoneNormalizer.normalize(query)
    end

    def slack_id_query(query)
      upcased = query.upcase
      upcased if upcased.match?(/\A[UW][A-Z0-9]{6,12}\z/)
    end

    def search_events(query)
      scope = if current_user.global_admin?
        Event.all
      else
        current_user.assigned_events
      end

      sanitized_like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      scope.where(
        "unaccent(name) ILIKE unaccent(:q) OR unaccent(location_city) ILIKE unaccent(:q) " \
        "OR unaccent(location_country) ILIKE unaccent(:q)",
        q: sanitized_like
      )
           .limit(5)
           .map do |e|
        {
          id: e.id,
          name: e.name,
          location: [ e.location_city, e.location_country ].compact.join(", "),
          url: select_admin_event_path(e)
        }
      end
    end

    def search_users(query)
      sanitized_like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      User.where(
        "email ILIKE :q OR UPPER(slack_user_id) = :slack_id",
        q: sanitized_like,
        slack_id: query.upcase
      )
          .limit(5)
          .map do |u|
        {
          id: u.id,
          email: u.email,
          role: user_role_label(u),
          url: admin_user_path(u)
        }
      end
    end

    def user_role_label(user)
      if user.global_admin?
        "Global Admin"
      elsif user.event_role_assignments.exists?
        "Staff"
      end
    end
  end
end
