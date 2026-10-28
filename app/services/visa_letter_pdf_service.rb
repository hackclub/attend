require "prawn"

# Renders a visa invitation letter: the Hack Foundation letterhead, the
# template's body filled in from the application's frozen details, the
# signature, and a footer repeating the applicant's name and birthday with
# the code embassies check at hack.club/visa-verify (which forwards to
# visas.hackclub.com/verify). Laid out after Envoy's letters.
#
# The PDF is locked against editing but can be printed and copied, as
# Envoy's were. Prawn's own encryption does this; there's no password to
# open it.
class VisaLetterPdfService
  FONT_SIZE = 10
  FOOTER_HEIGHT = 56
  SIGNATURE_HEIGHT = 80

  def initialize(application, template:)
    @application = application
    @template = template
  end

  def generate
    pdf = Prawn::Document.new(
      page_size: "LETTER",
      margin: [ 54, 54, 54 + FOOTER_HEIGHT, 54 ],
      info: { Title: "Visa invitation letter #{@application.reference_number}", Creator: "Hack Club" }
    )

    register_fonts(pdf)
    pdf.font "DejaVu"

    footer(pdf)
    header(pdf)
    pdf.move_down 24
    pdf.text @application.letter_issued_on.strftime("%B %-d, %Y"), size: FONT_SIZE
    pdf.move_down 16
    body(pdf)
    pdf.move_down 20
    signature(pdf)

    pdf.encrypt_document(
      user_password: "",
      owner_password: :random,
      permissions: { print_document: true, copy_contents: true, modify_contents: false, modify_annotations: false }
    )
    pdf.render
  end

  private

  # DejaVu Sans ships without italics here, so <i> in a template sets upright
  # text rather than failing to render.
  def register_fonts(pdf)
    normal = Rails.root.join("app/assets/fonts/DejaVuSans.ttf").to_s
    bold = Rails.root.join("app/assets/fonts/DejaVuSans-Bold.ttf").to_s
    pdf.font_families.update(
      "DejaVu" => { normal: normal, italic: normal, bold: bold, bold_italic: bold }
    )
  end

  def header(pdf)
    logo_path = Rails.root.join("public", "hackclub-logo.png")
    top = pdf.cursor

    pdf.image logo_path, width: 72, position: :left if File.exist?(logo_path)

    pdf.move_cursor_to top
    pdf.text "The Hack Foundation", size: 10, style: :bold, align: :right
    pdf.text "d.b.a. Hack Club", size: 9, align: :right
    pdf.text "8605 Santa Monica Blvd #86294", size: 9, align: :right
    pdf.text "West Hollywood, CA 90069", size: 9, align: :right
    pdf.text "team@hackclub.com", size: 9, align: :right
    pdf.text "EIN: 81-2908499", size: 9, align: :right
    pdf.move_cursor_to [ pdf.cursor, top - 72 ].min
  end

  def body(pdf)
    paragraphs = @template.render(@application).strip.split(/\n[ \t]*\n/)
    paragraphs.each_with_index do |paragraph, index|
      pdf.move_down 8 unless index.zero?
      pdf.text paragraph.strip, size: FONT_SIZE, leading: 2, inline_format: true
    end
  end

  # Kept together: a signature alone at the top of a page reads as forged.
  def signature(pdf)
    pdf.start_new_page if pdf.cursor < SIGNATURE_HEIGHT

    if @template.signature_image.attached?
      pdf.image StringIO.new(signature_png), height: 48
      pdf.move_down 4
    else
      pdf.move_down 36
    end
    pdf.text @template.signatory_name, size: FONT_SIZE, style: :bold
    pdf.text @template.signatory_title, size: FONT_SIZE
  end

  # Transparency flattened onto white, the paper it's printed on: Prawn's
  # handling of alpha channels fails on some perfectly good PNGs.
  def signature_png
    image = Vips::Image.new_from_buffer(@template.signature_image.download, "")
    image = image.flatten(background: 255) if image.has_alpha?
    image.write_to_buffer(".png")
  end

  # On every page, in the space the bottom margin leaves for it.
  def footer(pdf)
    marker = "AUTHENTIC DOCUMENT • #{@application.full_name.upcase} • DOB: #{@application.date_of_birth.iso8601}"

    pdf.repeat(:all, dynamic: true) do
      pdf.bounding_box([ 0, -10 ], width: pdf.bounds.width, height: FOOTER_HEIGHT - 10) do
        pdf.text_box ([ marker ] * 3).join(" • "), size: 6, color: "999999", height: 8, overflow: :shrink_to_fit, single_line: true
        pdf.move_down 14
        pdf.text "Hack Club is a 501(c)(3) public charity. Our nonprofit EIN is 81-2908499.", size: 8, align: :center
        pdf.text "Verify this letter at hack.club/visa-verify  |  Code: #{@application.verification_code}", size: 8, style: :bold, align: :center
      end
    end
  end
end
