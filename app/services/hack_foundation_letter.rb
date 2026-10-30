require "prawn"

# The Hack Foundation's letterhead, laid out the way Envoy printed visa
# letters, which is how embassies and schools know a letter from Hack Club:
# the wordmark and address, the body in Tinos (justified, as Envoy's HTML set
# it), a signature, a faint diagonal watermark inside a hairline border, and
# a navy-ruled footer with the recipient's name in microtext. Visa letters
# (VisaLetterPdfService) and school excuse letters (SchoolExcuseLetterService)
# both print on it.
#
# Envoy drew this as HTML in headless Chrome (app/views/layouts/pdf.html.erb
# there); the measurements below are its CSS in points (72 to the inch).
class HackFoundationLetter
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
  # Zach's, which Envoy signed every letter with unless its template had a
  # signature of its own.
  DEFAULT_SIGNATURE = Rails.root.join("lib/visa_letter/default-signature.png").to_s

  # `microtext` runs along the top of the footer. A `verification_code` is
  # printed beneath it, for embassies to check at hack.club/visa-verify.
  def initialize(title:, microtext:, verification_code: nil)
    @title = title
    @microtext = microtext
    @verification_code = verification_code
  end

  # Yields itself to write the body, between the date and the signature.
  # `signature` is an image to sign with, Zach's otherwise. With `lock`, the
  # PDF is locked against editing but can be printed and copied, as Envoy's
  # were; there's no password to open it.
  def render(date:, signatory_name:, signatory_title:, signature: nil, lock: false)
    @pdf = Prawn::Document.new(
      page_size: "LETTER",
      margin: [ TOP_MARGIN, SIDE_MARGIN, BOTTOM_MARGIN, SIDE_MARGIN ],
      info: { Title: @title, Creator: "Hack Club" }
    )

    register_fonts
    @pdf.font "Tinos", size: FONT_SIZE
    @pdf.default_leading leading(FONT_SIZE)

    page_furniture
    header
    @pdf.text date.strftime("%B %-d, %Y")
    @pdf.move_down 14.4
    yield self
    sign(signature, signatory_name, signatory_title)

    if lock
      @pdf.encrypt_document(
        user_password: "",
        owner_password: :random,
        permissions: { print_document: true, copy_contents: true, modify_contents: false, modify_annotations: false }
      )
    end
    @pdf.render
  end

  # Paragraphs separated by blank lines; a single line break stays a line
  # break, as Envoy's simple_format kept it. Prawn's inline <b> and <i> work,
  # so anything a person typed must be escaped first (see .escape).
  def paragraphs(text)
    text.gsub(/\r\n?/, "\n").strip.split(/\n[ \t]*\n/).each do |paragraph|
      @pdf.text paragraph.strip, align: :justify, inline_format: true
      @pdf.move_down PARAGRAPH_GAP
    end
  end

  # Prawn's inline format only understands these three entities.
  def self.escape(value)
    value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  private

  # Tinos is the font Envoy's letters were set in. DejaVu Sans stands in for
  # Envoy's Arial in the watermark and footer, and for any character Tinos
  # doesn't have, such as a name in another script.
  def register_fonts
    tinos = ->(style) { Rails.root.join("app/assets/fonts/tinos/Tinos-#{style}.ttf").to_s }
    @pdf.font_families.update(
      "Tinos" => { normal: tinos.("Regular"), bold: tinos.("Bold"), italic: tinos.("Italic"), bold_italic: tinos.("BoldItalic") },
      "DejaVu" => {
        normal: Rails.root.join("app/assets/fonts/DejaVuSans.ttf").to_s,
        bold: Rails.root.join("app/assets/fonts/DejaVuSans-Bold.ttf").to_s
      }
    )
    @pdf.fallback_fonts [ "DejaVu" ]
  end

  # Extra space between lines so they sit LINE_HEIGHT apart, as Envoy's CSS
  # line-height did.
  def leading(size)
    [ size * LINE_HEIGHT - @pdf.font.height_at(size), 0 ].max
  end

  # Drawn on every page, behind the letter: the border, the watermark and
  # the footer.
  def page_furniture
    @pdf.repeat(:all, dynamic: true) do
      @pdf.canvas do
        border
        watermark
        footer
      end
    end
  end

  def border
    @pdf.transparent(0.08) do
      @pdf.stroke_color NAVY
      @pdf.line_width 0.75
      @pdf.stroke_rectangle [ BORDER_INSET, @pdf.bounds.top - BORDER_INSET ],
        @pdf.bounds.width - BORDER_INSET * 2, @pdf.bounds.height - BORDER_INSET * 2
    end
  end

  def watermark
    text = "THE HACK FOUNDATION"
    size = 72
    center = [ @pdf.bounds.width / 2, @pdf.bounds.height / 2 ]

    @pdf.font("DejaVu", style: :bold, size: size) do
      width = @pdf.width_of(text)
      @pdf.transparent(0.03) do
        @pdf.fill_color NAVY
        @pdf.rotate(45, origin: center) do
          @pdf.draw_text text, at: [ center[0] - width / 2, center[1] - size * 0.36 ]
        end
      end
    end
    @pdf.fill_color "000000"
  end

  def header
    top = @pdf.cursor
    @pdf.image WORDMARK, width: 194.4

    @pdf.move_cursor_to top
    lines = [
      "<b>The Hack Foundation</b>",
      "<font size='9'><i>D.B.A Hack Club</i></font>",
      "8605 Santa Monica Boulevard #86294",
      "West Hollywood, CA 90069",
      "<u>team@hackclub.com</u>",
      "EIN: 81-2908499"
    ]
    @pdf.text lines.join("\n"), size: 10, leading: leading(10) - 1.5, align: :right, inline_format: true
  end

  # Kept together: a signature alone at the top of a page reads as forged.
  def sign(signature, name, title)
    needed = SIGNATURE_BOX[1] + FONT_SIZE * LINE_HEIGHT * 2
    @pdf.start_new_page if @pdf.cursor < needed

    @pdf.image StringIO.new(flattened_png(signature || File.binread(DEFAULT_SIGNATURE))), fit: SIGNATURE_BOX
    @pdf.text name
    @pdf.text title
  end

  # Transparency flattened onto white, the paper it's printed on: Prawn's
  # handling of alpha channels fails on some perfectly good PNGs.
  def flattened_png(image_data)
    image = Vips::Image.new_from_buffer(image_data, "")
    image = image.flatten(background: 255) if image.has_alpha?
    image.write_to_buffer(".png")
  end

  # Inside a navy rule, over a faint crosshatch: the microtext, Hack Club's
  # charity status, and the code embassies check if there is one.
  def footer
    left = SIDE_MARGIN
    width = @pdf.bounds.width - SIDE_MARGIN * 2
    top = FOOTER_BOTTOM + FOOTER_HEIGHT

    crosshatch(left, FOOTER_BOTTOM, width, FOOTER_HEIGHT)

    @pdf.stroke_color NAVY
    @pdf.line_width 1.5
    @pdf.stroke_horizontal_line left, left + width, at: top

    microtext(left, top, width)

    @pdf.font("Tinos") do
      # Centred in the footer when there's no code under it.
      charity_top = @verification_code ? top - 7.2 : top - (FOOTER_HEIGHT - 12) / 2
      @pdf.formatted_text_box [ { text: "Hack Club is a 501(c)(3) public charity. Our nonprofit EIN is 81-2908499.", size: 8, color: "666666" } ],
        at: [ left, charity_top ], width: width, height: 12, align: :center, valign: :center
      next unless @verification_code

      @pdf.formatted_text_box [
        { text: "Verify this letter at hack.club/visa-verify | Code: ", size: 7, color: "888888" },
        { text: @verification_code, font: "Courier", size: 8, color: "444444", character_spacing: 0.75 }
      ], at: [ left, top - 22.8 ], width: width, height: 12, align: :center, valign: :center
    end
  end

  # Repeated along the rule, letter-spaced, and cut off at its ends as
  # Envoy's overflow: hidden did.
  def microtext(left, top, width)
    @pdf.save_graphics_state do
      @pdf.rectangle [ left, top + 8 ], width, 8
      @pdf.add_content "W n"
      @pdf.transparent(0.3) do
        @pdf.fill_color NAVY
        @pdf.font("DejaVu", size: 4) do
          @pdf.character_spacing(1.1) { @pdf.draw_text ([ @microtext ] * 3).join(" • ") + " •", at: [ left, top + 2 ] }
        end
        @pdf.fill_color "000000"
      end
    end
  end

  # Envoy's two diagonal gradients: 1.5pt stripes every 3pt, each way, at 3%.
  def crosshatch(left, bottom, width, height)
    @pdf.save_graphics_state do
      @pdf.rectangle [ left, bottom + height ], width, height
      @pdf.add_content "W n"
      @pdf.transparent(0.03) do
        @pdf.stroke_color NAVY
        @pdf.line_width 1.5
        (-height..width).step(3) do |offset|
          @pdf.stroke_line [ left + offset, bottom ], [ left + offset + height, bottom + height ]
          @pdf.stroke_line [ left + offset, bottom + height ], [ left + offset + height, bottom ]
        end
      end
    end
  end
end
