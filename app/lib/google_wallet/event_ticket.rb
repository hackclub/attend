module GoogleWallet
  class EventTicket
    LOGO_URL = "https://assets.hackclub.com/icon-rounded.png".freeze
    HERO_IMAGE_URL = "https://attend.hackclub.com/banner.jpg".freeze

    attr_reader :participant_event

    def initialize(participant_event)
      @participant_event = participant_event
    end

    def save_url
      push_class_if_needed
      Rails.logger.info("Google Wallet: Signing ticket object with id: #{object_identifier}")
      jwt = sign_with_origins
      Rails.logger.info("Google Wallet: JWT generated successfully")
      "https://pay.google.com/gp/v/save/#{jwt}"
    end

    private

    def participant
      participant_event.participant
    end

    def event
      participant_event.event
    end

    def safeguarding_info
      participant_event.safeguarding_info
    end

    def class_identifier
      "event-#{event.id}"
    end

    def object_identifier
      "ticket-#{participant_event.id}"
    end

    def event_class
      @event_class ||= ::GoogleWallet::Resources::EventTicket::Class.new(
        attributes: class_attributes
      )
    end

    def ticket_object
      @ticket_object ||= ::GoogleWallet::Resources::EventTicket::Object.new(
        attributes: object_attributes,
        options: {
          barcode: {
            type: "QR_CODE",
            value: "attend://checkin/#{participant.id}",
            alternateText: participant.id.split("-").first.upcase
          }
        }
      )
    end

    def push_class_if_needed
      Rails.logger.info("Google Wallet: Pushing class with id: #{class_identifier}")
      push_class_with_logging
    end

    def push_class_with_logging
      require "httparty"

      access_token = ::GoogleWallet::Authentication.new.access_token
      class_id = event_class.id
      endpoint = "#{GoogleWallet.configuration.api_endpoint}/eventTicketClass"

      # Check if class exists
      get_response = HTTParty.get(
        "#{endpoint}/#{class_id}",
        query: { access_token: access_token }
      )

      if get_response.success?
        Rails.logger.info("Google Wallet: Class already exists, updating")
        response = HTTParty.put(
          "#{endpoint}/#{class_id}",
          query: { access_token: access_token },
          body: event_class.attributes.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      else
        Rails.logger.info("Google Wallet: Creating new class")
        response = HTTParty.post(
          endpoint,
          query: { access_token: access_token },
          body: event_class.attributes.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      if response.success?
        Rails.logger.info("Google Wallet: Class push successful")
      else
        Rails.logger.error("Google Wallet: Class push failed with status #{response.code}")
        Rails.logger.error("Google Wallet: Response body: #{response.body}")
        Rails.logger.error("Google Wallet: Class payload: #{event_class.attributes.to_json}")
      end

      response.success?
    end

    def sign_with_origins
      push_result = push_object_with_logging
      Rails.logger.info("Google Wallet: Object push result: #{push_result}")

      payload = {
        iss: GoogleWallet.configuration.json_credentials["client_email"],
        aud: "google",
        typ: "savetowallet",
        iat: Time.now.to_i,
        origins: allowed_origins,
        payload: {
          eventTicketObjects: [ { id: ticket_object.id } ]
        }
      }

      rsa_key = OpenSSL::PKey::RSA.new(GoogleWallet.configuration.json_credentials["private_key"])
      JWT.encode(payload, rsa_key, "RS256")
    end

    def allowed_origins
      origins = [ "https://attend.hackclub.com" ]
      origins << "https://attend.local" if Rails.env.development?
      origins
    end

    def push_object_with_logging
      require "httparty"

      access_token = ::GoogleWallet::Authentication.new.access_token
      object_id = ticket_object.id
      endpoint = "#{GoogleWallet.configuration.api_endpoint}/eventTicketObject"

      # Check if object exists
      get_response = HTTParty.get(
        "#{endpoint}/#{object_id}",
        query: { access_token: access_token }
      )

      if get_response.success?
        # Update existing object
        response = HTTParty.put(
          "#{endpoint}/#{object_id}",
          query: { access_token: access_token },
          body: ticket_object.attributes.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      else
        # Create new object
        response = HTTParty.post(
          endpoint,
          query: { access_token: access_token },
          body: ticket_object.attributes.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      end

      unless response.success?
        Rails.logger.error("Google Wallet: Object push failed with status #{response.code}")
        Rails.logger.error("Google Wallet: Response body: #{response.body}")
        Rails.logger.error("Google Wallet: Request payload: #{ticket_object.attributes.to_json}")
      end

      response.success?
    end

    def class_attributes
      attrs = {
        class_identifier: class_identifier,
        event_name: event.name,
        issuer_name: "Hack Club",
        logo_url: LOGO_URL,
        hero_image_url: hero_image_url
      }

      attrs[:event_id] = event.id
      attrs[:homepage_url] = "https://attend.hackclub.com/dashboard/events/#{event.id}"

      # Google requires venue to have BOTH name AND address, or neither
      if event.venue_name.present? && event.location_address.present?
        attrs[:venue_name] = event.venue_name
        attrs[:venue_address] = event.location_address
      end

      if event.starts_at.present?
        attrs[:start_date_time] = event_local(event.starts_at)
      end

      if event.ends_at.present?
        attrs[:end_date_time] = event_local(event.ends_at)
      end

      attrs[:hex_background_color] = "#B23444"

      attrs
    end

    def object_attributes
      attrs = {
        object_identifier: object_identifier,
        class_identifier: class_identifier,
        ticket_holder_name: attendee_display_name,
        ticket_number: participant.id.split("-").first.upcase
      }

      attrs[:gate] = freedom_waiver_status if event.freedom_waivers_enabled?

      if participant.tshirt_size.present?
        attrs[:section] = "T-Shirt: #{participant.tshirt_size.upcase}"
      end

      attrs[:ticket_type] = waiver_status

      if event.starts_at.present?
        attrs[:valid_time_start] = event_local(event.starts_at)
      end

      if event.ends_at.present?
        attrs[:valid_time_end] = event_local(event.ends_at.in_time_zone(event.event_time_zone).end_of_day)
      end

      attrs[:hex_background_color] = "#B23444"
      attrs[:grouping_id] = "event-#{event.id}"

      attrs
    end

    # Google treats an offset-less dateTime as local to the venue and displays
    # it verbatim, so times must be expressed in the event's timezone.
    def event_local(time)
      time.in_time_zone(event.event_time_zone).strftime("%Y-%m-%dT%H:%M")
    end

    # Google fetches this URL when rendering the pass, so it has to be public
    # and permanent — the storage proxy route gives us a non-expiring URL.
    def hero_image_url
      banner = event.effective_banner
      return HERO_IMAGE_URL unless banner

      Rails.application.routes.url_helpers.rails_storage_proxy_url(
        banner,
        host: "attend.hackclub.com",
        protocol: "https"
      )
    end

    def attendee_display_name
      first_name = participant.preferred_name.presence || participant.legal_first_name
      "#{first_name} #{participant.legal_last_name}"
    end

    def freedom_waiver_status
      if safeguarding_info&.freedom_waiver_granted?
        "Freedom: ✓"
      else
        "Freedom: ✗"
      end
    end

    def waiver_status
      if participant_event.waiver_signed?
        "Waiver Signed ✓"
      else
        "Waiver Pending"
      end
    end
  end
end
