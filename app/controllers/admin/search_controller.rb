module Admin
  class SearchController < BaseController
    def index
      query = params[:q].to_s.strip
      results = {}

      if query.present?
        results[:participants] = search_participants_fuzzy(query)
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
        scope.where("UPPER(slack_user_id) = ?", slack_id).limit(10).to_a
      else
        []
      end

      quoted_query = Participant.connection.quote(query)
      sanitized_like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"

      participants = scope
        .select(
          "participants.*",
          "GREATEST(
            COALESCE(similarity(legal_first_name, #{quoted_query}), 0),
            COALESCE(similarity(legal_last_name, #{quoted_query}), 0),
            COALESCE(similarity(email, #{quoted_query}), 0),
            COALESCE(similarity(preferred_name, #{quoted_query}), 0),
            COALESCE(similarity(CONCAT(legal_first_name, ' ', legal_last_name), #{quoted_query}), 0)
          ) AS relevance"
        )
        .where(
          "legal_first_name % :q OR legal_last_name % :q OR email % :q OR preferred_name % :q " \
          "OR CONCAT(legal_first_name, ' ', legal_last_name) % :q " \
          "OR legal_first_name ILIKE :like OR legal_last_name ILIKE :like OR email ILIKE :like",
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
      scope.where("name ILIKE :q OR location_city ILIKE :q OR location_country ILIKE :q", q: sanitized_like)
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
