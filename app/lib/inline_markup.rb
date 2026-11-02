# Escapes the three characters that act as markup in Prawn's inline format
# and in Slack message text, so a value a person typed shows as written.
module InlineMarkup
  def self.escape(value)
    value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end
end
