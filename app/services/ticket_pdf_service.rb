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
    boarding_pass_section(pdf)
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

  def boarding_pass_section(pdf)
    pass_height = 220
    stub_width = 120
    main_width = pdf.bounds.width - stub_width
    footer_height = 25

    pdf.bounding_box([ 0, pdf.cursor ], width: pdf.bounds.width, height: pass_height) do
      # Red header bar
      pdf.fill_color HACK_CLUB_RED
      pdf.fill_rectangle [ 0, pdf.bounds.height ], pdf.bounds.width, 35
      pdf.fill_color "FFFFFF"
      pdf.draw_text "BOARDING PASS", at: [ 15, pdf.bounds.height - 23 ], size: 14, style: :bold

      # Hack Club logo placeholder (text fallback)
      pdf.draw_text "HACK CLUB", at: [ pdf.bounds.width - 85, pdf.bounds.height - 23 ], size: 10, style: :bold

      # Main content area background
      content_top = pdf.bounds.height - 35
      content_height = pass_height - 35 - footer_height

      # Passenger and Status row
      pdf.fill_color LIGHT_TEXT
      pdf.draw_text "PASSENGER", at: [ 15, content_top - 20 ], size: 8
      pdf.fill_color DARK_TEXT
      pdf.draw_text @participant.display_name.upcase, at: [ 15, content_top - 35 ], size: 16, style: :bold

      pdf.fill_color LIGHT_TEXT
      pdf.draw_text "STATUS", at: [ 200, content_top - 20 ], size: 8
      pdf.fill_color HACK_CLUB_GREEN
      pdf.draw_text "CONFIRMED", at: [ 200, content_top - 35 ], size: 12, style: :bold

      # FROM / TO section
      from_y = content_top - 70
      pdf.fill_color LIGHT_TEXT
      pdf.draw_text "FROM", at: [ 40, from_y ], size: 8
      pdf.fill_color DARK_TEXT
      pdf.draw_text origin_code, at: [ 15, from_y - 22 ], size: 24, style: :bold
      pdf.fill_color LIGHT_TEXT
      pdf.draw_text @participant.city.presence || "Your City", at: [ 15, from_y - 38 ], size: 8

      # Dashed line with airplane
      line_y = from_y - 15
      pdf.stroke_color BORDER_COLOR
      pdf.dash(3, space: 2)
      pdf.stroke_line [ 100, line_y ], [ 180, line_y ]
      pdf.undash

      # Airplane icon (simple triangle representation)
      pdf.fill_color HACK_CLUB_RED
      airplane_x = 190
      pdf.fill_polygon [ airplane_x, line_y + 5 ], [ airplane_x + 15, line_y ], [ airplane_x, line_y - 5 ]

      pdf.dash(3, space: 2)
      pdf.stroke_color BORDER_COLOR
      pdf.stroke_line [ 210, line_y ], [ 270, line_y ]
      pdf.undash

      pdf.fill_color LIGHT_TEXT
      pdf.draw_text "TO", at: [ 305, from_y ], size: 8
      pdf.fill_color HACK_CLUB_RED
      pdf.draw_text destination_code, at: [ 285, from_y - 22 ], size: 24, style: :bold
      pdf.fill_color LIGHT_TEXT
      pdf.draw_text @event.location_city.presence || "Event Location", at: [ 285, from_y - 38 ], size: 8

      # Bottom info row (Event, Date, T-Shirt, Freedom)
      info_y = footer_height + 35
      col_width = 80

      pdf.stroke_color BORDER_COLOR
      pdf.stroke_line [ 15, info_y + 15 ], [ main_width - 15, info_y + 15 ]

      pdf.fill_color LIGHT_TEXT
      pdf.draw_text "EVENT", at: [ 15, info_y ], size: 8
      pdf.fill_color DARK_TEXT
      event_name = @event.name.truncate(12, omission: "")
      pdf.draw_text event_name, at: [ 15, info_y - 15 ], size: 11, style: :bold

      pdf.fill_color LIGHT_TEXT
      pdf.draw_text "DATE", at: [ 15 + col_width, info_y ], size: 8
      pdf.fill_color DARK_TEXT
      pdf.draw_text @event.starts_at&.strftime("%b %d") || "TBD", at: [ 15 + col_width, info_y - 15 ], size: 11, style: :bold

      pdf.fill_color LIGHT_TEXT
      pdf.draw_text "T-SHIRT", at: [ 15 + col_width * 2, info_y ], size: 8
      pdf.fill_color DARK_TEXT
      pdf.draw_text @participant.tshirt_size&.upcase || "—", at: [ 15 + col_width * 2, info_y - 15 ], size: 11, style: :bold

      if @event.freedom_waivers_enabled?
        pdf.fill_color LIGHT_TEXT
        pdf.draw_text "FREEDOM", at: [ 15 + col_width * 3, info_y ], size: 8
        if @participant_event.safeguarding_info&.freedom_waiver_granted?
          pdf.fill_color HACK_CLUB_GREEN
          pdf.draw_text "✓ YES", at: [ 15 + col_width * 3, info_y - 15 ], size: 11, style: :bold
        else
          pdf.fill_color HACK_CLUB_RED
          pdf.draw_text "✗ NO", at: [ 15 + col_width * 3, info_y - 15 ], size: 11, style: :bold
        end
      end

      # QR Code stub section (right side with gray background)
      stub_x = main_width
      pdf.fill_color "F9FAFC"
      pdf.fill_rectangle [ stub_x, pdf.bounds.height - 35 ], stub_width, content_height

      # Perforated edge circles
      circle_spacing = 28
      circle_count = 5
      start_y = pdf.bounds.height - 50
      pdf.fill_color "FFFFFF"
      circle_count.times do |i|
        pdf.fill_circle [ stub_x, start_y - (i * circle_spacing) ], 6
      end

      # QR section content
      stub_center = stub_x + (stub_width / 2)

      pdf.fill_color LIGHT_TEXT
      pdf.draw_text "SCAN TO CHECK IN", at: [ stub_x + 10, content_top - 20 ], size: 7

      # QR code with white background box
      qr_y = content_top - 35
      qr_size = 80
      pdf.fill_color "FFFFFF"
      pdf.stroke_color BORDER_COLOR
      pdf.fill_and_stroke_rounded_rectangle [ stub_center - 45, qr_y ], 90, 90, 6

      qr_code = RQRCode::QRCode.new(attend_deep_link(@participant.id))
      qr_png = qr_code.as_png(size: 200, border_modules: 0)
      qr_image = StringIO.new(qr_png.to_s)
      pdf.image qr_image, at: [ stub_center - 40, qr_y - 5 ], width: qr_size

      pdf.fill_color LIGHT_TEXT
      pdf.draw_text @participant_event.participant_id[0..7].upcase, at: [ stub_center - 28, qr_y - 100 ], size: 9

      # Black footer bar
      pdf.fill_color "17171D"
      pdf.fill_rectangle [ 0, footer_height ], pdf.bounds.width, footer_height
      pdf.fill_color LIGHT_TEXT
      pdf.draw_text "Please present this pass at registration", at: [ 15, 8 ], size: 8
      pdf.fill_color "FFFFFF"
      pdf.draw_text @event.slug.upcase, at: [ pdf.bounds.width - 80, 8 ], size: 9, style: :bold

      # Outer border
      pdf.stroke_color BORDER_COLOR
      pdf.stroke_rectangle [ 0, pdf.bounds.height ], pdf.bounds.width, pdf.bounds.height
    end
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
        time = leg.departure_time&.strftime("%b %d, %Y at %H:%M")
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
      "#{@event.starts_at.strftime('%B %d')} - #{@event.ends_at.strftime('%B %d, %Y')}"
    else
      @event.starts_at.strftime("%B %d, %Y")
    end
  end

  def origin_code
    @participant_event.origin_airport_code.presence || "HOME"
  end

  def destination_code
    @participant_event.destination_airport_code.presence || fallback_destination_code
  end

  def fallback_destination_code
    city = @event.location_city.to_s.upcase
    city.length >= 3 ? city[0..2] : "EVT"
  end

  def attend_deep_link(participant_id)
    "attend://checkin/#{participant_id}"
  end
end
