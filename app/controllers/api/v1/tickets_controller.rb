module Api
  module V1
    # Participant-facing API: lets a logged-in user fetch their own tickets
    # (participant_events) and wallet passes. This mirrors the cookie-authed
    # DashboardController, but scoped to the mobile bearer token.
    #
    # Ownership is guaranteed structurally: every record is loaded through
    # current_user.participant.participant_events, so a user can only ever see
    # their own tickets.
    class TicketsController < BaseController
      before_action :require_participant!
      before_action :set_ticket, only: [ :show, :google_wallet ]

      def index
        tickets = @participant.participant_events
          .includes(:event, :participant)
          .order(created_at: :desc)

        render json: { tickets: tickets.map { |pe| ticket_json(pe) } }
      end

      def show
        render json: { ticket: ticket_json(@ticket, detailed: true) }
      end

      # Google Wallet save URL generation hits Google's Walletobjects API, so it
      # is kept on-tap rather than computed for every ticket in the index.
      def google_wallet
        url = ::GoogleWallet::EventTicket.new(@ticket).save_url
        render json: { url: url }
      rescue StandardError => e
        Rails.logger.error("Google Wallet URL generation failed: #{e.class} - #{e.message}")
        Rails.logger.error(e.backtrace&.first(10)&.join("\n"))
        render json: { error: "Failed to generate Google Wallet pass" }, status: :unprocessable_entity
      end

      private

      def require_participant!
        @participant = current_user&.participant
        return if @participant

        render json: { error: "No participant profile for this account" }, status: :not_found
      end

      def set_ticket
        # Preloads mirror what ticket_json(detailed: true) actually reads:
        # display_status walks onboarding progress (travel, accommodation,
        # medical/dietary/accessibility, guardians + their emergency contacts,
        # consents, custom documents), checked_in? reads scans + scan contexts,
        # travel_json renders inbound legs, and event_json builds logo/banner
        # URLs. message_deliveries is intentionally absent — messages_json
        # builds its own filtered query.
        @ticket = @participant.participant_events
          .includes(
            :participant, :medical, :dietary, :accessibility, :accommodation,
            :travel_outbound, :consents,
            scans: :scan_context,
            guardian_participant_events: :emergency_contacts,
            travel_inbound: :travel_legs,
            event: [ :custom_documents, { logo_attachment: :blob }, { banner_attachment: :blob } ]
          )
          .find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Ticket not found" }, status: :not_found
      end

      def ticket_json(participant_event, detailed: false)
        event = participant_event.event
        participant = participant_event.participant

        # "Confirmed" = the attendee has finished onboarding. Only confirmed
        # tickets get a scannable check-in QR; others are sent to onboarding.
        confirmed = participant_event.display_status == "Complete"

        json = {
          id: participant_event.id,
          participant_id: participant.id,
          status: participant_event.status,
          display_status: participant_event.display_status,
          confirmed: confirmed,
          checked_in: participant_event.checked_in?,
          attendee_name: participant.display_name,
          # QR payload the scanner reads (same value the website encodes).
          qr_payload: "attend://checkin/#{participant.id}",
          short_code: participant.id.split("-").first.upcase,
          apple_wallet_url: apple_wallet_url(participant_event),
          onboarding_url: onboarding_url_for(event),
          event: event_json(event)
        }

        if detailed
          json[:can_download_ticket] = true
          json[:can_download_excuse_letter] = true
          json[:travel_inbound] = travel_json(participant_event.travel_inbound)
          json[:messages] = messages_json(participant_event)
        end

        json
      end

      # Delivered organizer messages for this ticket, newest first, de-duplicated
      # per message (a message may fan out to several channels).
      def messages_json(participant_event)
        deliveries = participant_event.message_deliveries
          .where(status: "delivered")
          .includes(message: :sent_by_user)
          .order(delivered_at: :desc)

        seen = {}
        deliveries.each_with_object([]) do |d, acc|
          m = d.message
          next if m.nil? || seen[m.id]

          seen[m.id] = true
          acc << {
            id: m.id,
            subject: m.subject,
            body: m.body,
            sender_name: m.sent_by_user&.name,
            delivered_at: d.delivered_at&.iso8601
          }
        end
      end

      def travel_json(travel)
        return nil unless travel

        {
          direction: travel.direction,
          mode: travel.mode,
          carrier: travel.carrier,
          flight_number: travel.flight_number,
          departure_city: travel.departure_city,
          arrival_city: travel.arrival_city,
          departure_time: travel.departure_time&.iso8601,
          arrival_time: travel.arrival_time&.iso8601,
          # The association is already scoped `order(position: :asc)`; a fresh
          # .order here would bypass the preload and re-query.
          legs: travel.travel_legs.map do |leg|
            {
              flight_code: leg.flight_code,
              departure_airport: leg.departure_airport,
              arrival_airport: leg.arrival_airport,
              departure_time: leg.departure_time&.iso8601,
              arrival_time: leg.arrival_time&.iso8601
            }
          end
        }
      end

      def onboarding_url_for(event)
        host = request.host_with_port
        protocol = request.protocol
        "#{protocol}#{host}/onboarding?event_id=#{event.id}"
      end

      def apple_wallet_url(participant_event)
        ::Passkit::UrlGenerator.new(::Passkit::EventTicket, participant_event).ios
      rescue StandardError => e
        Rails.logger.error("Apple Wallet URL generation failed: #{e.class} - #{e.message}")
        nil
      end

      def event_json(event)
        {
          id: event.id,
          name: event.name,
          slug: event.slug,
          starts_at: event.starts_at&.iso8601,
          ends_at: event.ends_at&.iso8601,
          timezone: event.timezone_identifier,
          location_city: event.location_city,
          location_address: event.location_address,
          location_country: event.location_country,
          location_latitude: event.location_latitude&.to_f,
          location_longitude: event.location_longitude&.to_f,
          logo_url: attachment_url_for(event.logo),
          banner_url: attachment_url_for(event.banner)
        }
      end

      def attachment_url_for(attachment)
        return nil unless attachment.attached?

        host = request.host_with_port
        protocol = request.protocol
        path = Rails.application.routes.url_helpers.rails_storage_proxy_path(attachment, only_path: true)
        "#{protocol}#{host}#{path}"
      rescue StandardError => e
        Rails.logger.error("Failed to generate attachment URL: #{e.message}")
        nil
      end
    end
  end
end
