# Participants routinely answer an optional free-text medical question with
# "None" or "N/A" rather than leaving it empty, and that answer then reads as
# real content everywhere downstream — a field showing "None" looks filled-in
# next to one that is genuinely blank, and staff have to read every box to tell
# the difference. Collapse those answers to NULL as they are written so blank
# means one thing across the admin views, exports, API and wallet passes.
#
# Only whole-value matches are cleared. "No known allergies" and "none that
# need refrigeration" are real answers and must survive untouched, so this
# never does substring matching.
#
# `normalizes` runs on assignment and on write, not on load, so values already
# in the database keep whatever text they hold until the record is next saved.
# Readers that interpret legacy text — see Medical::NEGATIVE_RESPONSES, whose
# list is deliberately broader than this one — still need to.
module ClearsNegativeResponses
  extend ActiveSupport::Concern

  # Deliberately narrow. Ambiguous answers ("nil", "-", "0") are left for a
  # human to read rather than silently dropped from a medical record.
  BLANK_EQUIVALENTS = %w[no none n/a na].freeze

  # A trailing full stop is tolerated ("None.") because it is punctuation, not
  # content. Anything else keeps the participant's own text, stripped.
  NORMALIZER = lambda do |value|
    text = value.to_s.strip
    return nil if text.empty?

    BLANK_EQUIVALENTS.include?(text.downcase.delete_suffix(".")) ? nil : text
  end

  class_methods do
    def clears_negative_responses(*names)
      normalizes(*names, with: NORMALIZER)
    end
  end
end
