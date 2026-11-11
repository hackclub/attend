# Content template SIDs for WhatsApp messages we start. Meta only lets a
# business open a WhatsApp conversation with a pre-approved template; the
# wording lives in the Twilio Content Template Builder, not here.
module WhatsappTemplates
  BROADCAST = "HX03810127184385b6ecf8fc5638a00faf".freeze
  INCIDENT_REPORT_RECEIVED = "HXeb91ad61c5db91f70ebaae16e01441da".freeze
  INCIDENT_REPORT_UPDATE = "HXaf78008ce63a6fa4416351255c16f537".freeze
  SUPPORT_NEW_TICKET = "HX9c45afb230bdc0b1c7c27f602ad25aed".freeze
  SUPPORT_TICKET_REPLY = "HX5ca4001b1dcf1acc2f01832527415b53".freeze

  # Meta rejects template variables that are empty or contain newlines, tabs
  # or runs of spaces, so every value goes through here.
  def self.variable(text, limit: 200)
    text.to_s.squish.truncate(limit).presence || "-"
  end
end
