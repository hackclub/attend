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

    # Trust & Safety line, also quoted in the emergency back field.
    SAFETY_PHONE_URL = "tel://+18556254225".freeze

    # Keys outside the passkit gem's vocabulary, merged into pass.json by
    # PasskitGeneratorExtensions. Blank values are dropped there.
    def additional_pass_keys
      {
        # Wallet validates schemes in order and renders the first that fits,
        # so iOS 17 and anything missing artwork still gets the classic layout.
        preferredStyleSchemes: %w[posterEventTicket eventTicket],
        eventLogoText: event.name,
        featuredActions: featured_actions,
        directionsInformationURL: apple_maps_url,
        contactVenueEmail: event.effective_support_email
      }
    end

    # iOS 27 draws up to two of these as tiles under the pass, in array
    # order. Directions comes first when we know the venue's Apple Maps
    # place; the safety line is always there.
    def featured_actions
      actions = []
      if event.apple_place_id.present?
        actions << { identifier: "directions", type: "place", placeIdentifier: event.apple_place_id }
      end
      actions << { identifier: "safety-call", type: "call", url: SAFETY_PHONE_URL }
      actions
    end

    # Most venues never get an Apple place id (Apple's POI coverage is patchy
    # outside the US), so fall back to a coordinate link: the pass keeps a
    # working directions link and only the iOS 27 tile needs the id.
    def apple_maps_url
      if event.apple_place_id.present?
        "https://maps.apple.com/place?place-id=#{event.apple_place_id}"
      elsif event.location_latitude.present? && event.location_longitude.present?
        query = { ll: "#{event.location_latitude.to_f},#{event.location_longitude.to_f}", q: event.venue_name.presence || event.name }
        "https://maps.apple.com/?#{query.to_query}"
      end
    end

    def semantics
      tags = {
        eventName: event.name,
        eventType: "PKEventTypeConvention",
        attendeeName: attendee_display_name
      }

      if event.freedom_waivers_enabled?
        # Staff read this at the door, so the negative is spelled out rather
        # than implied by a generic level.
        tags[:admissionLevel] = freedom_waiver_granted? ? "Freedom Waiver" : "No Freedom Waiver"
        tags[:admissionLevelAbbreviation] = freedom_waiver_granted? ? "FW ✓" : "NO FW"
      end

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

    # Strip sizes are what Apple's Pass Designer validates event tickets
    # against (375x144pt) and match the shipped defaults in
    # private/passkit/event_ticket. Artwork and background are what the poster
    # event ticket layout needs (480x340pt, as the designer exports them);
    # without both, Wallet falls back to the classic layout.
    BANNER_IMAGES = {
      "strip.png" => [ 375, 144 ], "strip@2x.png" => [ 750, 288 ], "strip@3x.png" => [ 1125, 432 ],
      "artwork@2x.png" => [ 960, 680 ], "artwork@3x.png" => [ 1440, 1020 ],
      "background@2x.png" => [ 960, 680 ], "background@3x.png" => [ 1440, 1020 ]
    }.freeze
    # Poster layout logos: primaryLogo is the square mark next to
    # eventLogoText (48x48pt), secondaryLogo the wide one in the footer
    # (160x50pt, same bounds as the classic logo).
    LOGO_IMAGES = {
      "primaryLogo@2x.png" => [ 96, 96 ], "primaryLogo@3x.png" => [ 144, 144 ],
      "secondaryLogo@2x.png" => [ 320, 100 ], "secondaryLogo@3x.png" => [ 480, 150 ]
    }.freeze

    # Rendered pass images, kept on local disk per original blob, so a pod
    # renders an event's images once rather than for every pass it builds.
    IMAGE_CACHE = Rails.root.join("tmp/passkit_images").freeze

    # Render the event's banner and logo (falling back to its series') into
    # the pass bundle. Any failure leaves the shipped defaults in place.
    def add_other_files(path)
      write_images(path, event.effective_banner, BANNER_IMAGES, :resize_to_fill)
      write_images(path, event.effective_logo, LOGO_IMAGES, :resize_to_fit)
    end

    private

    def write_images(path, attachment, images, mode)
      return unless attachment&.variable?

      render_missing_images(attachment.blob, images.values.uniq, mode)
      images.each do |name, size|
        FileUtils.cp(rendered_image_path(attachment.blob, mode, size), File.join(path, name))
      end
    rescue StandardError => e
      Rails.logger.error("Passkit: failed to render #{images.keys.first.split('@').first} images, using defaults: #{e.message}")
    end

    # Renders from one download of the original instead of through
    # ActiveStorage variants, which download the original, upload the result
    # and download that again for every size: eleven sizes made a pass for an
    # event with new artwork take over 30 seconds to build.
    def render_missing_images(blob, sizes, mode)
      missing = sizes.reject { |size| rendered_image_path(blob, mode, size).exist? }
      return if missing.empty?

      FileUtils.mkdir_p(IMAGE_CACHE.join(blob.key))
      blob.open do |original|
        missing.each do |size|
          target = rendered_image_path(blob, mode, size)
          ActiveStorage::Variation.wrap(mode => size, format: :png).transform(original) do |output|
            # Rename into place so a concurrent build never copies half a file
            partial = "#{target}.#{SecureRandom.hex(4)}"
            FileUtils.cp(output.path, partial)
            File.rename(partial, target)
          end
        end
      end
    end

    def rendered_image_path(blob, mode, size)
      IMAGE_CACHE.join(blob.key, "#{mode}-#{size.join('x')}.png")
    end

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
