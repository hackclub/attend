# A letter for a participant to show at a border they can cross without a
# visa, such as between the US and Canada, saying why they're visiting: who
# invited them, to what, when and where, that they won't be working, and
# that they'll go home afterwards. On the Hack Foundation's letterhead
# (HackFoundationLetter) and signed by Zach, like the school excuse letter.
#
# It only says what Attend can stand behind: what Hack Club covers only if
# the event's staff have written it (Event#invitation_letter_costs), and a
# minor's parent or guardian only once that guardian has signed.
class InvitationLetterService
  PHONE = "+1 (855) 625-4225".freeze

  def initialize(participant_event)
    @participant_event = participant_event
    @participant = participant_event.participant
    @event = participant_event.event
  end

  def generate
    letter = HackFoundationLetter.new(
      title: "#{@event.name} invitation letter",
      microtext: "AUTHENTIC DOCUMENT • #{@participant.full_name.upcase} • #{@event.name.upcase}"
    )
    letter.render(date: Date.current, signatory_name: "Zach Latta", signatory_title: "Executive Director") do |page|
      page.paragraphs([
        "To the Border Services Officer,", invitation_paragraph, purpose_paragraph, costs_paragraph,
        guardian_paragraph, departure_paragraph, contact_paragraph, "Sincerely,"
      ].compact.join("\n\n"))
    end
  end

  private

  # Names and places go into Prawn's inline format, so their own < and &
  # mustn't read as tags.
  def h(value)
    HackFoundationLetter.escape(value)
  end

  def invitation_paragraph
    born = " born #{date(@participant.date_of_birth)}," if @participant.date_of_birth
    "The Hack Foundation (d.b.a. Hack Club), a 501(c)(3) nonprofit organization based in the United States, " \
      "has invited <b>#{h @participant.full_name}</b>,#{born} to attend <b>#{h @event.name}</b>, " \
      "taking place#{" #{dates}" if dates} at #{h location}."
  end

  def purpose_paragraph
    "#{h @event.name} is a free educational event for teenagers. Participants spend the event learning to " \
      "program and building projects of their own design alongside students from around the world. " \
      "#{h first_name} is attending as a participant only. They will not be employed, paid or doing any " \
      "business during their visit."
  end

  def costs_paragraph
    h(@event.invitation_letter_costs.to_s.strip).presence
  end

  # Only for someone under 18 at the event, and only once a guardian has
  # signed for them, so the letter can name who consented.
  def guardian_paragraph
    return unless @event.local_start_date && @participant.minor_on?(@event.local_start_date)
    return if consenting_guardian.nil?

    "#{h first_name} is under 18. Their parent or guardian, #{h consenting_guardian.full_name}, has given " \
      "written consent for them to attend, and the event is supervised by Hack Club staff throughout."
  end

  def consenting_guardian
    @consenting_guardian ||= @participant_event.consents.signed.where.not(guardian_signed_at: nil)
      .where.not(guardian_participant_event_id: nil).order(:guardian_signed_at).first&.guardian_participant_event&.guardian
  end

  def departure_paragraph
    ending = " when the event ends on #{date(@event.local_end_date)}" if @event.local_end_date
    "We expect #{h first_name} to leave the country#{ending} and return home."
  end

  def contact_paragraph
    "If you have any questions about #{h first_name}'s visit, please contact us at " \
      "#{h @event.effective_support_email} or #{PHONE}."
  end

  def first_name
    @participant.legal_first_name.presence || @participant.full_name
  end

  def dates
    starts = @event.local_start_date
    ends = @event.local_end_date
    return if starts.nil?
    return "on #{date(starts)}" if ends.nil? || ends == starts

    "from #{date(starts)} to #{date(ends)}"
  end

  # The venue and as much of its address as the event has, without saying
  # the city or country twice when the address already includes them.
  def location
    address = @event.location_address.to_s
    parts = [ @event.venue_name, address ]
    [ @event.location_city, @event.location_country ].each do |part|
      parts << part unless part.blank? || address.downcase.include?(part.downcase)
    end
    parts.compact_blank.uniq.join(", ").presence || "a location to be confirmed"
  end

  def date(value)
    value.strftime("%B %-d, %Y")
  end
end
