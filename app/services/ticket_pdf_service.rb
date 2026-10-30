require "prawn"
require "prawn/table"

class TicketPdfService
  HACK_CLUB_RED = "EC3750"
  HACK_CLUB_GREEN = "33D6A6"
  DARK_TEXT = "1F2D3D"
  LIGHT_TEXT = "8492A6"
  BORDER_COLOR = "E0E6ED"

  def initialize(participant_event)
    @participant_event = participant_event
    @participant = participant_event.participant
    @event = participant_event.event
  end

  def generate
    pdf = Prawn::Document.new(page_size: "A4", margin: 40)

    pdf.font_families.update(
      "DejaVu" => {
        normal: Rails.root.join("app/assets/fonts/DejaVuSans.ttf").to_s,
        bold: Rails.root.join("app/assets/fonts/DejaVuSans-Bold.ttf").to_s
      }
    )
    pdf.font "DejaVu"

    header_section(pdf)
    pdf.move_down 30
    ticket_section(pdf)
    pdf.move_down 30
    personal_info_section(pdf)
    pdf.move_down 25
    travel_info_section(pdf)
    pdf.move_down 25
    event_info_section(pdf)

    pdf.render
  end

  private

  def header_section(pdf)
    logo_path = Rails.root.join("public", "hackclub-logo.png")
    if File.exist?(logo_path)
      pdf.image logo_path, width: 50, position: :left
      pdf.move_up 40
      pdf.indent(60) do
        pdf.text @event.name, size: 24, style: :bold, color: DARK_TEXT
        pdf.text "Event Ticket", size: 12, color: LIGHT_TEXT
        if group_label
          pdf.text group_label, size: 11, style: :bold, color: HACK_CLUB_RED
        end
      end
    else
      pdf.text @event.name, size: 24, style: :bold, color: DARK_TEXT
      pdf.text "Event Ticket", size: 12, color: LIGHT_TEXT
      pdf.text group_label, size: 11, style: :bold, color: HACK_CLUB_RED if group_label
    end
  end

  def group_label
    return nil unless @event.groups_enabled?
    names = @participant_event.groups.ordered.map(&:name)
    return nil if names.empty?
    names.join(" • ")
  end

  def ticket_section(pdf)
    pass_height = 165
    header_height = 35
    qr_box = 90

    pdf.bounding_box([ 0, pdf.cursor ], width: pdf.bounds.width, height: pass_height) do
      # Red header bar
      pdf.fill_color HACK_CLUB_RED
      pdf.fill_rectangle [ 0, pdf.bounds.height ], pdf.bounds.width, header_height
      pdf.fill_color "FFFFFF"
      pdf.draw_text "ENTRY TICKET", at: [ 15, pdf.bounds.height - 23 ], size: 14, style: :bold

      # Hack Club logo placeholder (text fallback)
      pdf.draw_text "HACK CLUB", at: [ pdf.bounds.width - 85, pdf.bounds.height - 23 ], size: 10, style: :bold

      # Name, event, date and city down the left
      content_top = pdf.bounds.height - header_height - 15
      text_width = pdf.bounds.width - qr_box - 45

      pdf.fill_color DARK_TEXT
      pdf.text_box @participant.display_name, at: [ 15, content_top ], width: text_width, height: 22,
        size: 16, style: :bold, overflow: :shrink_to_fit
      pdf.text_box @event.name, at: [ 15, content_top - 26 ], width: text_width, height: 16,
        size: 12, overflow: :shrink_to_fit
      pdf.fill_color LIGHT_TEXT
      pdf.text_box date_and_city, at: [ 15, content_top - 46 ], width: text_width, height: 14, size: 10

      if @event.freedom_waivers_enabled?
        if @participant_event.safeguarding_info&.freedom_waiver_granted?
          pdf.fill_color HACK_CLUB_GREEN
          freedom_label = "✓ Freedom waiver"
        else
          pdf.fill_color HACK_CLUB_RED
          freedom_label = "✗ No freedom waiver"
        end
        pdf.text_box freedom_label, at: [ 15, content_top - 68 ], width: text_width, height: 14, size: 10, style: :bold
      end

      # QR code with white background box
      qr_x = pdf.bounds.width - qr_box - 15
      pdf.fill_color "FFFFFF"
      pdf.stroke_color BORDER_COLOR
      pdf.fill_and_stroke_rounded_rectangle [ qr_x, content_top ], qr_box, qr_box, 6

      qr_code = RQRCode::QRCode.new(attend_deep_link(@participant.id))
      qr_png = qr_code.as_png(size: 200, border_modules: 0)
      qr_image = StringIO.new(qr_png.to_s)
      pdf.image qr_image, at: [ qr_x + 5, content_top - 5 ], width: qr_box - 10

      pdf.fill_color LIGHT_TEXT
      pdf.draw_text "Show this QR code when you arrive", at: [ 15, 12 ], size: 8

      # Outer border
      pdf.stroke_color BORDER_COLOR
      pdf.stroke_rectangle [ 0, pdf.bounds.height ], pdf.bounds.width, pdf.bounds.height
    end
  end

  def date_and_city
    [ @event.local_starts_at&.strftime("%b %-d"), @event.location_city.presence ].compact.join(" · ")
  end

  def personal_info_section(pdf)
    pdf.fill_color DARK_TEXT
    pdf.text "PERSONAL INFORMATION", size: 11, style: :bold
    pdf.move_down 12

    data = [
      [ "Name", @participant.display_name ],
      [ "Email", @participant.email ],
      [ "Phone", @participant.phone.presence || "—" ],
      [ "Pronouns", @participant.pronouns.presence || "—" ],
      [ "T-Shirt Size", @participant.tshirt_size&.upcase || "—" ]
    ]

    info_table(pdf, data)
  end

  def travel_info_section(pdf)
    pdf.fill_color DARK_TEXT
    pdf.text "TRAVEL INFORMATION", size: 11, style: :bold
    pdf.move_down 12

    inbound = @participant_event.travel_inbound
    outbound = @participant_event.travel_outbound

    if inbound.present? || outbound.present?
      data = []

      if inbound.present?
        data << [ "Arriving", format_travel(inbound) ]
      end

      if outbound.present?
        data << [ "Departing", format_travel(outbound) ]
      end

      info_table(pdf, data) if data.any?
    else
      pdf.fill_color LIGHT_TEXT
      pdf.text "No travel information submitted", size: 10
    end
  end

  def format_travel(travel)
    parts = []

    if travel.plane? && travel.travel_legs.any?
      travel.travel_legs.each do |leg|
        flight_info = leg.flight_code.to_s
        route = "#{leg.departure_airport} → #{leg.arrival_airport}"
        time = leg.local_departure_time&.strftime("%b %d, %Y at %H:%M %Z")
        parts << [ flight_info, route, time ].compact.join("  ")
      end
    else
      mode = travel.mode.to_s.capitalize
      route = [ travel.departure_city, travel.arrival_city ].compact.join(" → ")
      time = travel.departure_time&.strftime("%b %d, %Y at %H:%M")
      parts << [ mode, route.presence, time ].compact.join("  ")
    end

    parts.join("\n")
  end

  def event_info_section(pdf)
    pdf.fill_color DARK_TEXT
    pdf.text "EVENT DETAILS", size: 11, style: :bold
    pdf.move_down 12

    data = [
      [ "Event", @event.name ],
      [ "Location", [ @event.location_city, @event.location_country ].compact.join(", ") ],
      [ "Dates", format_event_dates ]
    ]
    data << [ "Group", group_label ] if group_label

    info_table(pdf, data)
  end

  def info_table(pdf, data)
    pdf.table(data, width: pdf.bounds.width, cell_style: { borders: [ :bottom ], border_color: BORDER_COLOR, padding: [ 8, 5 ] }) do
      column(0).style(font_style: :bold, text_color: LIGHT_TEXT, width: 100)
      column(1).style(text_color: DARK_TEXT)
    end
  end

  def format_event_dates
    return "TBD" unless @event.starts_at.present?

    if @event.ends_at.present?
      "#{@event.local_starts_at.strftime('%B %d')} - #{@event.local_ends_at.strftime('%B %d, %Y')}"
    else
      @event.local_starts_at.strftime("%B %d, %Y")
    end
  end

  def attend_deep_link(participant_id)
    "attend://checkin/#{participant_id}"
  end
end
