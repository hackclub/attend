module Api
  module V1
    module Series
      # Events inside one series, addressed with a single series API key.
      #
      # Creating an event is the one write in the whole API that *requires* a
      # series API key: a mobile token, a global token and an event key are all
      # refused, because an event has to land in a series and only a series key
      # names one unambiguously. The series comes from the key, never from the
      # request body — a client cannot create an event anywhere else, even by
      # passing a different `event_series_id`.
      #
      # Everything the web's new-event form requires is required here too
      # (`name` and `support_email`, the latter on a Hack Club domain), and
      # everything the rest of the web's setup wizard *accepts* — schedule,
      # location, module toggles — may be sent in the same call.
      class EventsController < BaseController
        include Pundit::Authorization
        include Api::V1::SeriesScoped
        include Api::V1::EventSerialization

        rescue_from Pundit::NotAuthorizedError do
          render json: { error: "Forbidden" }, status: :forbidden
        end

        before_action :require_series_api_key!, only: [ :create ]
        before_action :set_event, only: [ :show, :update ]

        def index
          events = @series.events
            .includes(:event_series)
            .order(Arel.sql("starts_at ASC NULLS LAST"))

          render json: { events: events.map { |event| series_event_json(event, summary: true) } }
        end

        def show
          render json: { event: series_event_json(@event) }
        end

        def create
          if foreign_series_id?
            return render json: {
              error: "A series API key can only create events in its own series (#{@series.slug}); " \
                     "remove event_series_id or set it to #{@series.id}."
            }, status: :forbidden
          end

          missing = REQUIRED_ON_CREATE.reject { |field| params.dig(:event, field).present? }
          if missing.any?
            return render json: { error: "#{missing.join(' and ')} #{missing.one? ? 'is' : 'are'} required" },
                          status: :unprocessable_entity
          end

          @event = Event.new(event_params.merge(event_series: @series))

          if @event.save
            grant_token_owner_event_admin
            log_event_change(:record_create)
            render json: { event: series_event_json(@event) }, status: :created
          else
            render json: { error: @event.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        end

        def update
          if @event.update(event_params)
            log_event_change(:record_update)
            render json: { event: series_event_json(@event) }
          else
            render json: { error: @event.errors.full_messages.to_sentence }, status: :unprocessable_entity
          end
        end

        private

        # Mirrors the two fields the web's new-event form marks required (name
        # is validated by the model, support_email by both). Everything else on
        # that form — slug, timezone, logo — is optional there and optional here.
        REQUIRED_ON_CREATE = %i[name support_email].freeze

        def require_series_api_key!
          return if current_series_from_api_key

          render json: {
            error: "Creating an event requires a series API key. " \
                   "Issue one from the series' API page in the Attend dashboard."
          }, status: :forbidden
        end

        # The series is taken from the key, so a body that names a *different*
        # one is a client bug worth reporting rather than silently overriding.
        def foreign_series_id?
          supplied = params.dig(:event, :event_series_id).presence
          return false if supplied.blank?

          ![ @series.id, @series.slug ].include?(supplied.to_s)
        end

        def set_event
          @event = @series.events.find_by(id: params[:id]) || @series.events.find_by(slug: params[:id])

          # Deliberately 404 rather than 403 for an event in another series:
          # from this key's point of view the event does not exist, and saying
          # otherwise would confirm a slug the caller has no standing over.
          return render json: { error: "Event not found in this series" }, status: :not_found if @event.nil?

          Current.event = @event

          if api_key_request?
            require_api_key_event_scope!(@event)
          else
            authorize @event, :update?
          end
        end

        # Same permitted set as the web's Admin::EventsController#event_params,
        # minus the attachments (logos are uploaded from the dashboard) and
        # minus event_series_id, which the key decides. Keep the two in step.
        def event_params
          params.require(:event).permit(
            :name,
            :slug,
            :starts_at,
            :ends_at,
            :registration_open_at,
            :registration_close_at,
            :location_city,
            :location_country,
            :location_address,
            :location_latitude,
            :location_longitude,
            :venue_name,
            :timezone,
            :support_email,
            :freedom_waivers_enabled,
            :travel_enabled,
            :visa_options_enabled,
            :visa_application_url,
            :accommodation_enabled,
            :roommate_preferences_enabled,
            :guardian_invites_locked,
            :hotel_scan_context_id,
            :nfc_badges_enabled,
            :nfc_badge_write_on_checkin_enabled,
            :groups_enabled
          )
        end

        # The web gives a series member who creates an event an explicit
        # event_admin role (Admin::EventsController#ensure_creator_has_admin_role)
        # so per-event staff tooling reflects them. An API-created event has no
        # signed-in creator, so the token's owner stands in — they're the series
        # member who issued the key.
        def grant_token_owner_event_admin
          owner = current_series_api_token&.user
          return if owner.nil? || owner.global_admin?

          @event.event_role_assignments.find_or_create_by!(user: owner, role: "event_admin")
        end

        # API-key requests have no current_user, so the token's owner is the
        # closest thing to an actor; the key's id goes in the metadata either
        # way so a series key's writes are attributable.
        def log_event_change(action)
          AuditLog.log!(
            action: action,
            record: @event,
            actor: current_user || current_series_api_token&.user,
            event: @event,
            changed_fields: @event.previous_changes.except("created_at", "updated_at"),
            metadata: {
              ip: request.remote_ip,
              user_agent: request.user_agent,
              source: "series_api",
              series_id: @series.id,
              # The key's id, not its name: audit_logs.metadata is stored in
              # clear text, and an id is provably not a credential. It also
              # outlives a rename or a rotation, and revoking a key keeps its
              # row, so this always resolves to the key that acted.
              series_api_token_id: current_series_api_token&.id
            }.compact
          )
        rescue StandardError => e
          Rails.logger.error("[SeriesApi] Failed to write audit log: #{e.class} - #{e.message}")
          Sentry.capture_exception(e) if defined?(Sentry)
        end
      end
    end
  end
end
