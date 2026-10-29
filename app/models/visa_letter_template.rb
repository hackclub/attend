# The wording of a visa invitation letter. One active global default, and
# optionally an event's own. The body is plain text with {{placeholders}}:
# paragraphs are separated by blank lines, single line breaks are kept, and
# Prawn's inline tags (<b>, <i>, <u>) work. Envoy's templates came across
# unchanged apart from <strong>/<em> becoming <b>/<i>.
class VisaLetterTemplate < ApplicationRecord
  include DecodableImageAttachment

  has_paper_trail

  self.implicit_order_column = "created_at"

  belongs_to :event, optional: true
  has_one_attached :signature_image

  PLACEHOLDERS = %w[
    participant_full_name
    participant_date_of_birth
    participant_country_of_birth
    participant_place_of_birth
    participant_phone_number
    participant_address
    participant_email
    event_name
    event_venue
    event_address
    event_city
    event_country
    event_start_date
    event_end_date
    event_date_range
    reference_number
    current_date
    signatory_name
    signatory_title
  ].freeze

  SIGNATURE_CONTENT_TYPES = %w[image/png image/jpeg].freeze

  # Where a new template starts: Envoy's default wording, without the
  # sign-off block it repeated after the signature.
  STARTER_BODY = <<~BODY.freeze
    To Whom It May Concern,

    The Hack Foundation, doing business as Hack Club, is pleased to confirm that {{participant_full_name}} has been invited to attend {{event_name}}.

    Participant Information:
    Full Name: {{participant_full_name}}
    Date of Birth: {{participant_date_of_birth}}
    Country of Citizenship: {{participant_country_of_birth}}
    Email: {{participant_email}}
    Phone: {{participant_phone_number}}
    Address: {{participant_address}}

    Event Details:
    Event Name: {{event_name}}
    Event Dates: {{event_date_range}}
    Venue: {{event_venue}}
    Address: {{event_address}}, {{event_city}}, {{event_country}}

    Hack Club is a 501(c)(3) nonprofit organization (EIN: 81-2908499) that supports a global community of high school hackers and makers. We organize events, hackathons, and educational programs to help young people learn to code and build technology.

    {{participant_full_name}} is invited to participate in this event as an attendee. The participant is responsible for their own travel, accommodation, and living expenses during the event. Hack Club will not be financially responsible for the participant during their stay.

    This letter is issued solely for the purpose of supporting a visa application.

    Reference Number: {{reference_number}}

    Sincerely,
  BODY

  validates :name, :signatory_name, :signatory_title, presence: true
  validates :body, presence: true, length: { minimum: 100 }
  validate :one_global_default, if: -> { is_default? && event_id.nil? }
  validate :signature_image_type

  scope :active, -> { where(active: true) }

  def self.default_template
    active.find_by(is_default: true, event_id: nil)
  end

  # The event's own template when it has an active one, otherwise the
  # global default. Nil when neither exists.
  def self.for_event(event)
    active.where(event: event).order(created_at: :desc).first || default_template
  end

  # The letter for a made-up applicant, so admins can check wording and
  # layout before anyone receives it. Uses the template's event when it has
  # one, otherwise an example event.
  def preview_pdf
    event = self.event
    application = VisaLetterApplication.new(
      full_name: "Ada Example", email: "ada@example.com", date_of_birth: Date.new(2008, 4, 1),
      nationality: "Exampleland", place_of_birth: "Example City", phone: "+12025550123",
      address: "2 Sample Road, Example City, Exampleland",
      reference_number: "HC-PREVIEW", verification_code: "0" * 32,
      letter_event_name: event&.name || "Example Hackathon",
      letter_venue: event&.venue_name || "Example Hall",
      letter_address: event&.location_address || "1 Example Street",
      letter_city: event&.location_city || "Boston",
      letter_country: event&.location_country || "United States",
      letter_starts_on: event&.local_start_date || 2.months.from_now.to_date,
      letter_ends_on: event&.local_end_date || (2.months.from_now + 2.days).to_date,
      letter_issued_on: Date.current
    )
    VisaLetterPdfService.new(application, template: self).generate
  end

  # The body with every placeholder filled in from the application's frozen
  # copy of the applicant and event details, escaped so applicant input
  # can't inject Prawn's inline tags.
  def render(application)
    values = placeholder_values(application)
    body.gsub(/\{\{\s*(\w+)\s*\}\}/) do
      key = Regexp.last_match(1)
      values.key?(key) ? escape(values[key]) : Regexp.last_match(0)
    end
  end

  private

  def placeholder_values(application)
    {
      "participant_full_name" => application.full_name,
      "participant_date_of_birth" => application.date_of_birth&.strftime("%B %-d, %Y"),
      "participant_country_of_birth" => application.nationality,
      "participant_place_of_birth" => application.place_of_birth,
      "participant_phone_number" => application.phone,
      "participant_address" => application.address,
      "participant_email" => application.email,
      "event_name" => application.letter_event_name,
      "event_venue" => application.letter_venue,
      "event_address" => application.letter_address,
      "event_city" => application.letter_city,
      "event_country" => application.letter_country,
      "event_start_date" => application.letter_starts_on&.strftime("%B %-d, %Y"),
      "event_end_date" => application.letter_ends_on&.strftime("%B %-d, %Y"),
      "event_date_range" => application.letter_date_range,
      "reference_number" => application.reference_number,
      "current_date" => application.letter_issued_on&.strftime("%B %-d, %Y"),
      "signatory_name" => signatory_name,
      "signatory_title" => signatory_title
    }
  end

  # Prawn's inline format only understands these three entities.
  def escape(value)
    value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  def one_global_default
    others = self.class.where(is_default: true, event_id: nil).where.not(id: id)
    errors.add(:is_default, "is already set on another template") if others.exists?
  end

  # Prawn embeds the image itself, and only reads PNG and JPEG.
  def signature_image_type
    return unless signature_image.attached?

    unless SIGNATURE_CONTENT_TYPES.include?(signature_image.blob.content_type)
      errors.add(:signature_image, "must be a PNG or JPEG")
      return
    end
    validate_decodable_image(:signature_image)
  end
end
