require "prawn"

# Renders a visa invitation letter the way Envoy did, so a letter from Attend
# looks like every letter embassies have seen from Hack Club: the Hack
# Foundation wordmark and address, the template's body in Tinos (justified,
# as Envoy's HTML set it), Zach's signature unless the template has its own,
# a faint diagonal watermark inside a hairline border, and a footer repeating
# the applicant's name and birthday with the code embassies check at
# hack.club/visa-verify (which forwards to visas.hackclub.com/verify).
#
# Envoy drew this as HTML in headless Chrome (app/views/layouts/pdf.html.erb
# there); the measurements below are its CSS in points (72 to the inch).
#
# The PDF is locked against editing but can be printed and copied, as
# Envoy's were. Prawn's own encryption does this; there's no password to
# open it.
class VisaLetterPdfService
  NAVY = "1A3A5C"
  FONT_SIZE = 11
  LINE_HEIGHT = 1.5
  PARAGRAPH_GAP = 10.8
  SIDE_MARGIN = 46.8
  TOP_MARGIN = 36
  # The footer sits 0.4in above the page's bottom edge; the body stops short
  # of it.
  FOOTER_BOTTOM = 28.8
  FOOTER_HEIGHT = 42
  BOTTOM_MARGIN = FOOTER_BOTTOM + FOOTER_HEIGHT + 10
  BORDER_INSET = 21.6
  SIGNATURE_BOX = [ 108, 57.6 ].freeze
  WORDMARK = Rails.root.join("lib/visa_letter/hack-foundation-wordmark.png").to_s
  DEFAULT_SIGNATURE = Rails.root.join("lib/visa_letter/default-signature.png").to_s

  def initialize(application, template:)
    @application = application
    @template = template
  end

  def generate
    pdf = Prawn::Document.new(
      page_size: "LETTER",
      margin: [ TOP_MARGIN, SIDE_MARGIN, BOTTOM_MARGIN, SIDE_MARGIN ],
      info: { Title: "Visa invitation letter #{@application.reference_number}", Creator: "Hack Club" }
    )

    register_fonts(pdf)
    pdf.font "Tinos", size: FONT_SIZE
    pdf.default_leading leading(pdf, FONT_SIZE)

    page_furniture(pdf)
    header(pdf)
    pdf.text @application.letter_issued_on.strftime("%B %-d, %Y")
    pdf.move_down 14.4
    body(pdf)
    signature(pdf)

    pdf.encrypt_document(
      user_password: "",
      owner_password: :random,
      permissions: { print_document: true, copy_contents: true, modify_contents: false, modify_annotations: false }
    )
    pdf.render
  end

  private

  # Tinos is the font Envoy's letters were set in. DejaVu Sans stands in for
  # Envoy's Arial in the watermark and footer, and for any character Tinos
  # doesn't have, such as a name in another script.
  def register_fonts(pdf)
    tinos = ->(style) { Rails.root.join("app/assets/fonts/tinos/Tinos-#{style}.ttf").to_s }
    pdf.font_families.update(
      "Tinos" => { normal: tinos.("Regular"), bold: tinos.("Bold"), italic: tinos.("Italic"), bold_italic: tinos.("BoldItalic") },
      "DejaVu" => {
        normal: Rails.root.join("app/assets/fonts/DejaVuSans.ttf").to_s,
        bold: Rails.root.join("app/assets/fonts/DejaVuSans-Bold.ttf").to_s
      }
    )
    pdf.fallback_fonts [ "DejaVu" ]
  end

  # Extra space between lines so they sit LINE_HEIGHT apart, as Envoy's CSS
  # line-height did.
  def leading(pdf, size)
    [ size * LINE_HEIGHT - pdf.font.height_at(size), 0 ].max
  end

  # Drawn on every page, behind the letter: the border, the watermark and
  # the footer.
  def page_furniture(pdf)
    pdf.repeat(:all, dynamic: true) do
      pdf.canvas do
        border(pdf)
        watermark(pdf)
        footer(pdf)
      end
    end
  end

  def border(pdf)
    pdf.transparent(0.08) do
      pdf.stroke_color NAVY
      pdf.line_width 0.75
      pdf.stroke_rectangle [ BORDER_INSET, pdf.bounds.top - BORDER_INSET ],
        pdf.bounds.width - BORDER_INSET * 2, pdf.bounds.height - BORDER_INSET * 2
    end
  end

  def watermark(pdf)
    text = "THE HACK FOUNDATION"
    size = 72
    center = [ pdf.bounds.width / 2, pdf.bounds.height / 2 ]

    pdf.font("DejaVu", style: :bold, size: size) do
      width = pdf.width_of(text)
      pdf.transparent(0.03) do
        pdf.fill_color NAVY
        pdf.rotate(45, origin: center) do
          pdf.draw_text text, at: [ center[0] - width / 2, center[1] - size * 0.36 ]
        end
      end
    end
    pdf.fill_color "000000"
  end

  def header(pdf)
    top = pdf.cursor
    pdf.image WORDMARK, width: 194.4

    pdf.move_cursor_to top
    lines = [
      "<b>The Hack Foundation</b>",
      "<font size='9'><i>D.B.A Hack Club</i></font>",
      "8605 Santa Monica Boulevard #86294",
      "West Hollywood, CA 90069",
      "<u>team@hackclub.com</u>",
      "EIN: 81-2908499"
    ]
    pdf.text lines.join("\n"), size: 10, leading: leading(pdf, 10) - 1.5, align: :right, inline_format: true
  end

  # The template's paragraphs, separated by blank lines; a single line break
  # stays a line break, as Envoy's simple_format kept it.
  def body(pdf)
    paragraphs = @template.render(@application).gsub(/\r\n?/, "\n").strip.split(/\n[ \t]*\n/)
    paragraphs.each do |paragraph|
      pdf.text paragraph.strip, align: :justify, inline_format: true
      pdf.move_down PARAGRAPH_GAP
    end
  end

  # Kept together: a signature alone at the top of a page reads as forged.
  def signature(pdf)
    needed = SIGNATURE_BOX[1] + FONT_SIZE * LINE_HEIGHT * 2
    pdf.start_new_page if pdf.cursor < needed

    pdf.image StringIO.new(signature_png), fit: SIGNATURE_BOX
    pdf.text @template.signatory_name
    pdf.text @template.signatory_title
  end

  # The template's own signature if it has one, otherwise the one Envoy
  # printed on every letter. Transparency flattened onto white, the paper
  # it's printed on: Prawn's handling of alpha channels fails on some
  # perfectly good PNGs.
  def signature_png
    source = @template.signature_image.attached? ? @template.signature_image.download : File.binread(DEFAULT_SIGNATURE)
    image = Vips::Image.new_from_buffer(source, "")
    image = image.flatten(background: 255) if image.has_alpha?
    image.write_to_buffer(".png")
  end

  # Inside a navy rule, over a faint crosshatch: the applicant's name and
  # birthday in microtext, Hack Club's charity status, and the code
  # embassies check.
  def footer(pdf)
    left = SIDE_MARGIN
    width = pdf.bounds.width - SIDE_MARGIN * 2
    top = FOOTER_BOTTOM + FOOTER_HEIGHT

    crosshatch(pdf, left, FOOTER_BOTTOM, width, FOOTER_HEIGHT)

    pdf.stroke_color NAVY
    pdf.line_width 1.5
    pdf.stroke_horizontal_line left, left + width, at: top

    marker = "AUTHENTIC DOCUMENT • #{@application.full_name.upcase} • DOB: #{@application.date_of_birth.iso8601}"
    pdf.save_graphics_state do
      pdf.rectangle [ left, top + 8 ], width, 8
      pdf.add_content "W n"
      pdf.transparent(0.3) do
        pdf.fill_color NAVY
        pdf.font("DejaVu", size: 4) do
          pdf.character_spacing(1.1) { pdf.draw_text ([ marker ] * 3).join(" • ") + " •", at: [ left, top + 2 ] }
        end
        pdf.fill_color "000000"
      end
    end

    pdf.font("Tinos") do
      pdf.formatted_text_box [ { text: "Hack Club is a 501(c)(3) public charity. Our nonprofit EIN is 81-2908499.", size: 8, color: "666666" } ],
        at: [ left, top - 7.2 ], width: width, height: 12, align: :center, valign: :center
      pdf.formatted_text_box [
        { text: "Verify this letter at hack.club/visa-verify | Code: ", size: 7, color: "888888" },
        { text: @application.verification_code, font: "Courier", size: 8, color: "444444", character_spacing: 0.75 }
      ], at: [ left, top - 22.8 ], width: width, height: 12, align: :center, valign: :center
    end
  end

  # Envoy's two diagonal gradients: 1.5pt stripes every 3pt, each way, at 3%.
  def crosshatch(pdf, left, bottom, width, height)
    pdf.save_graphics_state do
      pdf.rectangle [ left, bottom + height ], width, height
      pdf.add_content "W n"
      pdf.transparent(0.03) do
        pdf.stroke_color NAVY
        pdf.line_width 1.5
        (-height..width).step(3) do |offset|
          pdf.stroke_line [ left + offset, bottom ], [ left + offset + height, bottom + height ]
          pdf.stroke_line [ left + offset, bottom + height ], [ left + offset + height, bottom ]
        end
      end
    end
  end
end
