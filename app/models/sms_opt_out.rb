# A number that asked for no more automated texts, by SMS or WhatsApp. Set by
# replying STOP (or one of Twilio's other opt-out words) or through the link
# at the bottom of texts sent from the "Hack Club" sender, which can't take
# replies. Removed by replying START or from the link page.
#
# Covers automated messages only: broadcasts, incident updates, support
# notifications. Codes someone asks for (Twilio Verify) and support agents'
# replies in a conversation the person started still go through.
class SmsOptOut < ApplicationRecord
  include NormalizesPhoneNumbers
  self.implicit_order_column = "created_at"

  # Twilio's default keywords, so a word that stops our long code's texts at
  # Twilio stops them here too.
  STOP_WORDS = %w[STOP STOPALL UNSUBSCRIBE CANCEL END QUIT OPTOUT REVOKE].freeze
  START_WORDS = %w[START UNSTOP YES].freeze

  enum :source, { keyword: "keyword", link: "link" }

  normalizes_phone_number :phone_number
  validates :phone_number, :opted_out_at, presence: true

  def self.opted_out?(phone)
    phone.present? && exists?(phone_number: phone)
  end

  def self.opt_out!(phone, source:)
    upsert({ phone_number: phone, source: source.to_s, opted_out_at: Time.current },
           unique_by: :phone_number, update_only: %i[source opted_out_at])
  end

  def self.opt_in!(phone)
    where(phone_number: phone).delete_all
  end

  # :stop, :start or nil for an inbound message's body. Twilio also sends
  # OptOutType when it recognised the word itself.
  def self.keyword_action(body, opt_out_type: nil)
    word = opt_out_type.presence || body.to_s.strip.upcase.delete(" ")
    return :stop if STOP_WORDS.include?(word)
    :start if START_WORDS.include?(word)
  end

  # The opt-out link's token: the number's digits plus a short signature,
  # short enough to fit at the bottom of a text.
  def self.token_for(phone)
    digits = phone.to_s.delete("^0-9")
    "#{digits}-#{signature(digits)}"
  end

  # The E.164 number a token stands for, or nil if it's been tampered with.
  def self.phone_for_token(token)
    digits, sig = token.to_s.split("-", 2)
    return unless digits.present? && sig.present?
    return unless ActiveSupport::SecurityUtils.secure_compare(sig, signature(digits))

    "+#{digits}"
  end

  def self.signature(digits)
    key = Rails.application.key_generator.generate_key("sms opt-out link", 32)
    Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", key, digits), padding: false)[0, 10]
  end
  private_class_method :signature
end
