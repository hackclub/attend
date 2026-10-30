# A letter for a participant to give their school, excusing them for the
# event, on the Hack Foundation's letterhead (HackFoundationLetter: the same
# design as visa letters, after Envoy's) and signed by Zach.
class SchoolExcuseLetterService
  def initialize(participant_event)
    @participant_event = participant_event
    @participant = participant_event.participant
    @event = participant_event.event
  end

  def generate
    letter = HackFoundationLetter.new(
      title: "#{@event.name} school excuse letter",
      microtext: "AUTHENTIC DOCUMENT • #{@participant.full_name.upcase} • #{@event.name.upcase}"
    )
    letter.render(date: Date.current, signatory_name: "Zach Latta", signatory_title: "Executive Director") do |page|
      page.paragraphs([ "To Whom It May Concern,", intro_paragraph, nonprofit_paragraph, mission_paragraph,
        closing_paragraph, "Sincerely," ].join("\n\n"))
    end
  end

  private

  # Names and places go into Prawn's inline format, so their own < and &
  # mustn't read as tags.
  def h(value)
    HackFoundationLetter.escape(value)
  end

  def intro_paragraph
    "On behalf of The Hack Foundation, please excuse <b>#{h @participant.full_name}</b> " \
      "from your institution through the dates of #{format_date_range}, " \
      "as they will be attending Hack Club's <b>#{h @event.name}</b> hackathon " \
      "in #{h event_location}. " \
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
      "like #{h @event.name}; we've run hackathons on trains, private islands, and 3-day hiking " \
      "trips. Attendance at these hackathons is a life-changing opportunity and an achievement in " \
      "itself, as they all feature intensive coding requirements for qualification."
  end

  def closing_paragraph
    contact_email = @event.effective_support_email

    "You can expect your student to come home with new programming skills, interesting travel " \
      "stories to share with their teachers, and a bounty of new international friendships. " \
      "Please direct all questions and consultations via email to #{h contact_email}, " \
      "or call +1 (855) 625-4225. Hack Club is excited to host the student mentioned herein, " \
      "and thanks you for your understanding and cooperation."
  end

  def format_date_range
    return "TBD" unless @event.starts_at.present?

    start_date = @event.local_starts_at.strftime("%B %-d")

    if @event.ends_at.present?
      end_date = if @event.local_starts_at.year == @event.local_ends_at.year &&
                    @event.local_starts_at.month == @event.local_ends_at.month
        "the #{@event.local_ends_at.strftime('%-d')}"
      else
        @event.local_ends_at.strftime("%B %-d")
      end

      "#{start_date} to #{end_date} of #{(@event.local_ends_at || @event.local_starts_at).strftime('%Y')}"
    else
      start_date
    end
  end

  def event_location
    [ @event.location_city, @event.location_country ].compact.reject(&:blank?).join(", ").presence || "the event location"
  end
end
