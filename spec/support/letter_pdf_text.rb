# A letter's text, line by line in the order it's drawn (the watermark and
# footer overlap the body, which scrambles the reader's page layout), without
# the 72pt watermark, whose rotated letters would otherwise land between
# lines of the body.
module LetterPdfText
  def letter_text(pdf)
    PDF::Reader.new(StringIO.new(pdf)).pages.flat_map do |page|
      page.runs(merge: true).reject { |run| run.font_size > 20 }.map(&:text)
    end.join(" ").squish
  end
end

RSpec.configure do |config|
  config.include LetterPdfText
end
