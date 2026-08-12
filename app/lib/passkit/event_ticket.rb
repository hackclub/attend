module Passkit
  class EventTicket < BasePass
    def pass_type
      "eventTicket"
    end

    def organization_name
      "Hack Club"
    end

    def description
      "#{event.name} Ticket"
    end

    def logo_text
      event.name
    end

    def foreground_color
      "rgb(255, 255, 255)"
    end

    def background_color
      "rgb(178, 52, 68)"
    end

    def label_color
      "rgb(255, 255, 255)"
    end

    def primary_fields
      [
        {
          key: "event",
          label: "EVENT",
          value: event.name
        }
      ]
    end

    def header_fields
      return [] unless event.freedom_waivers_enabled?

      [
        {
          key: "freedom",
          label: "FREEDOM",
          value: freedom_waiver_granted? ? "✓ YES" : "✗ NO"
        }
      ]
    end

    def secondary_fields
      fields = []
      fields << {
        key: "attendee",
        label: "ATTENDEE",
        value: attendee_display_name.upcase
      }
      if event.starts_at.present?
        fields << {
          key: "date",
          label: "DATE",
          value: event.starts_at.in_time_zone(event.event_time_zone).strftime("%b %d, %Y")
        }
      end
      fields
    end

    def auxiliary_fields
      fields = []

      if participant.tshirt_size.present?
        fields << {
          key: "tshirt",
          label: "T-SHIRT",
          value: participant.tshirt_size.upcase
        }
      end

      # Show venue name if set, otherwise fall back to city
      location_display = event.venue_name.presence || event.location_city
      if location_display.present?
        fields << {
          key: "location",
          label: "LOCATION",
          value: location_display
        }
      end

      fields
    end

    def freedom_waiver_granted?
      participant_event.safeguarding_info&.freedom_waiver_granted || false
    end

    def relevant_date
      event.starts_at&.iso8601
    end

    def relevant_dates
      return [] unless event.starts_at.present? && event.ends_at.present?

      [
        {
          startDate: event.starts_at.iso8601,
          endDate: event.ends_at.iso8601
        }
      ]
    end

    def expiration_date
      return if event.ends_at.blank?

      # Keep the pass valid until the day after the event ends, so it doesn't
      # expire while attendees are still travelling home.
      (event.ends_at + 1.day).end_of_day.iso8601
    end

    def locations
      return [] unless event.location_latitude.present? && event.location_longitude.present?

      welcome_text = if event.venue_name.present?
        "Welcome to #{event.venue_name} for #{event.name}!"
      else
        "Welcome to #{event.name}!"
      end

      [
        {
          latitude: event.location_latitude.to_f,
          longitude: event.location_longitude.to_f,
          relevantText: welcome_text
        }
      ]
    end

    def back_fields
      fields = [
        {
          key: "info",
          label: "About This Pass",
          value: "Present this pass at registration to check in to #{event.name}. Keep your phone charged!"
        },
        {
          key: "email",
          label: "Email",
          value: participant.email
        }
      ]

      if event.starts_at.present?
        fields << {
          key: "start_time",
          label: "Event Starts",
          value: event.starts_at.in_time_zone(event.event_time_zone).strftime("%B %d, %Y at %I:%M %p")
        }
      end

      if event.ends_at.present?
        fields << {
          key: "end_time",
          label: "Event Ends",
          value: event.ends_at.in_time_zone(event.event_time_zone).strftime("%B %d, %Y at %I:%M %p")
        }
      end

      if event.venue_name.present? || event.location_address.present?
        venue_parts = [ event.venue_name, event.location_address ].compact
        fields << {
          key: "venue",
          label: "Venue",
          value: venue_parts.join("\n")
        }
      end

      fields << {
        key: "participant_id",
        label: "Participant ID",
        value: participant.id
      }

      fields << {
        key: "dashboard",
        label: "Your Dashboard",
        value: "https://attend.hackclub.com/dashboard/events/#{event.id}",
        attributedValue: "<a href='https://attend.hackclub.com/dashboard/events/#{event.id}'>View your event dashboard</a>"
      }

      fields << {
        key: "support",
        label: "Need Help?",
        value: "Contact the event organizers or visit hackclub.com"
      }

      fields << {
        key: "emergency",
        label: "Emergency Contact",
        value: "In an emergency, contact the Trust & Safety Team at Hack Club by calling +1 (855) 625 4225, or +1 (802) 233 3223 on WhatsApp."
      }

      fields
    end

    def barcodes
      [
        {
          messageEncoding: "iso-8859-1",
          format: "PKBarcodeFormatQR",
          message: "attend://checkin/#{participant.id}",
          altText: participant.id.split("-").first.upcase
        }
      ]
    end

    def semantics
      tags = {
        eventName: event.name,
        eventType: "PKEventTypeConvention",
        attendeeName: attendee_display_name
      }

      if event.starts_at.present?
        tags[:eventStartDate] = event.starts_at.iso8601
      end

      if event.ends_at.present?
        tags[:eventEndDate] = event.ends_at.iso8601
      end

      if event.venue_name.present?
        tags[:venueName] = event.venue_name
      end

      if event.location_latitude.present? && event.location_longitude.present?
        tags[:venueLocation] = {
          latitude: event.location_latitude.to_f,
          longitude: event.location_longitude.to_f
        }
      end

      tags
    end

    def file_name
      @file_name ||= SecureRandom.uuid
    end

    # Replace the default strip images with the event's banner (falling back
    # to its series' banner), if one is set.
    # Sizes match the shipped strip.png/strip@2x.png in private/passkit/event_ticket.
    def add_other_files(path)
      banner = event.effective_banner
      return unless banner

      { "strip.png" => [ 750, 246 ], "strip@2x.png" => [ 1500, 492 ] }.each do |name, size|
        variant = banner.variant(resize_to_fill: size, format: :png).processed
        File.binwrite(File.join(path, name), variant.download)
      end
    rescue StandardError => e
      Rails.logger.error("Passkit: failed to render event banner strip, using default: #{e.message}")
    end

    private

    def folder_name
      "event_ticket"
    end

    def participant_event
      raise ActiveRecord::RecordNotFound, "participant event not found for pass" if @generator.nil?

      @generator
    end

    def participant
      participant_event.participant
    end

    def event
      participant_event.event
    end

    def attendee_display_name
      first_name = participant.preferred_name.presence || participant.legal_first_name
      "#{first_name} #{participant.legal_last_name}"
    end
  end
end
