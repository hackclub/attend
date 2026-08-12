require "prawn"

class SchoolExcuseLetterService
  def initialize(participant_event)
    @participant_event = participant_event
    @participant = participant_event.participant
    @event = participant_event.event
  end

  def generate
    pdf = Prawn::Document.new(
      page_size: "LETTER",
      margin: [ 54, 54, 54, 54 ] # 0.75in margins
    )

    register_fonts(pdf)
    pdf.font "DejaVu"

    header(pdf)
    pdf.move_down 40
    salutation(pdf)
    pdf.move_down 20
    body_paragraphs(pdf)
    pdf.move_down 30
    closing(pdf)

    pdf.render
  end

  private

  def register_fonts(pdf)
    pdf.font_families.update(
      "DejaVu" => {
        normal: Rails.root.join("app/assets/fonts/DejaVuSans.ttf").to_s,
        bold: Rails.root.join("app/assets/fonts/DejaVuSans-Bold.ttf").to_s
      }
    )
  end

  def header(pdf)
    logo_path = Rails.root.join("public", "hackclub-logo.png")

    if File.exist?(logo_path)
      pdf.image logo_path, width: 80, position: :left
    end

    pdf.move_up 60
    pdf.text "The Hack Foundation d.b.a Hack Club", size: 10, align: :right
    pdf.text "8605 Santa Monica Blvd #86294", size: 10, align: :right
    pdf.text "West Hollywood, CA 90069", size: 10, align: :right
  end

  def salutation(pdf)
    pdf.text "To Whom It May Concern,", size: 11
  end

  def body_paragraphs(pdf)
    pdf.text intro_paragraph, size: 11, leading: 4, inline_format: true
    pdf.move_down 14
    pdf.text nonprofit_paragraph, size: 11, leading: 4
    pdf.move_down 14
    pdf.text mission_paragraph, size: 11, leading: 4
    pdf.move_down 14
    pdf.text closing_paragraph, size: 11, leading: 4
  end

  def intro_paragraph
    "On behalf of The Hack Foundation, please excuse <b>#{@participant.full_name}</b> " \
      "from your institution through the dates of #{format_date_range}, " \
      "as they will be attending Hack Club's <b>#{@event.name}</b> hackathon " \
      "in #{event_location}. " \
      "This is an educational computer programming event wherein the student will " \
      "construct various projects of their own design with other teenagers from around the world."
  end

  def nonprofit_paragraph
    "This event is hosted by Hack Club, a 501(c)(3) non-profit operating in the United States, " \
      "legally represented by The Hack Foundation, which bears the EIN 81-2908499. Hack Club has " \
      "been financially supported and backed by innovators like Tom Preston-Werner and Michael Dell, " \
      "featured in publications like The Wall Street Journal, and is regularly recognized as one of " \
      "the largest non-profits in computer science education, with clubs and events all over the world."
  end

  def mission_paragraph
    "As part of its mission to promote teenagers in tech, Hack Club regularly organizes events " \
      "like #{@event.name}; we've run hackathons on trains, private islands, and 3-day hiking " \
      "trips. Attendance at these hackathons is a life-changing opportunity and an achievement in " \
      "itself, as they all feature intensive coding requirements for qualification."
  end

  def closing_paragraph
    contact_email = @event.effective_support_email

    "You can expect your student to come home with new programming skills, interesting travel " \
      "stories to share with their teachers, and a bounty of new international friendships. " \
      "Please direct all questions and consultations via email to #{contact_email}, " \
      "or call +1 (855) 625-4225. Hack Club is excited to host the student mentioned herein, " \
      "and thanks you for your understanding and cooperation."
  end

  def closing(pdf)
    pdf.text "Sincerely,", size: 11
    pdf.move_down 40
    pdf.text "Zach Latta", size: 11, style: :bold
    pdf.text "Executive Director", size: 11
  end

  def format_date_range
    return "TBD" unless @event.starts_at.present?

    start_date = @event.starts_at.strftime("%B %-d")

    if @event.ends_at.present?
      end_date = if @event.starts_at.year == @event.ends_at.year &&
                    @event.starts_at.month == @event.ends_at.month
        "the #{@event.ends_at.strftime('%-d')}"
      else
        @event.ends_at.strftime("%B %-d")
      end

      "#{start_date} to #{end_date} of #{(@event.ends_at || @event.starts_at).strftime('%Y')}"
    else
      start_date
    end
  end

  def event_location
    [ @event.location_city, @event.location_country ].compact.reject(&:blank?).join(", ").presence || "the event location"
  end
end
