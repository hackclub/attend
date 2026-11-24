require "openssl"

# What a participant's check-in QR code says, and how a scanner tells a real
# one from a made-up one without asking the server.
#
# A signed code is `ATTEND://CHECKIN/T.<base32>`, where the decoded bytes are
#
#   version (1) | key id (1) | participant_event id (16) | signature (64)
#
# The signature is ECDSA P-256 over SHA-256 of
#
#   version (1) | key id (1) | event id (16) | participant_event id (16)
#
# as raw r || s (the form WebCrypto verifies). The event id is signed but not
# written into the code: the scanner knows which event it is at and checks
# against that, so a ticket for one event fails at another's door, and the
# code is 16 bytes shorter. Uppercase base32 keeps the QR in alphanumeric
# mode, which packs far denser than bytes; the signed code comes out as dense
# as the old unsigned one. Nothing personal is in it.
#
# Only the server holds the private key. The scanner is handed the public
# keys and checks codes on the device, so it can turn away a forged code even
# with no connection.
#
# Signing is off until keys are configured, under credentials
# `ticket_signing.keys` (key id => PEM private key; the highest id signs).
# Until then, and for anything issued before, the code is the old unsigned
# `attend://checkin/<participant id>`, which the scanner still accepts but
# can only vouch for online.
module CheckinCode
  PREFIX = "attend://checkin/".freeze
  SIGNED_PREFIX = "ATTEND://CHECKIN/".freeze
  SIGNED_MARKER = "T.".freeze
  VERSION = 1
  CODE_BYTES = 18
  SIGNATURE_BYTES = 64
  CURVE = "prime256v1".freeze
  DETERMINISTIC = { "nonce-type" => "1" }.freeze
  BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".freeze

  class Invalid < StandardError
    def initialize(msg = "This is not a valid ticket for this event")
      super
    end
  end

  module_function

  # The code to put in a participant's QR: signed when keys are configured.
  def for(participant_event)
    return "#{PREFIX}#{participant_event.participant_id}" unless signing_enabled?

    "#{SIGNED_PREFIX}#{sign(event_id: participant_event.event_id, participant_event_id: participant_event.id)}"
  end

  def signing_enabled?
    keyring.any?
  end

  # The `T.` token on its own, without the deep link prefix.
  def sign(event_id:, participant_event_id:)
    key_id = keyring.keys.max
    code = [ VERSION, key_id ].pack("CC") + uuid_bytes(participant_event_id)
    signature = raw_signature(keyring.fetch(key_id), signed_message(code, event_id))
    "#{SIGNED_MARKER}#{base32_encode(code + signature)}"
  end

  # True for anything shaped like a signed code, with or without the prefix.
  # Shaped like one is not the same as valid; see .verify!.
  def signed?(value)
    strip_prefix(value).upcase.start_with?(SIGNED_MARKER)
  end

  # The participant_event id a signed code names, once its signature checks
  # out for this event. Raises Invalid otherwise: forged, damaged, signed with
  # a key we don't hold, or issued for a different event, which a scanner
  # can't tell apart.
  def verify!(value, event:)
    bytes = base32_decode(strip_prefix(value).upcase.delete_prefix(SIGNED_MARKER))
    raise Invalid unless bytes && bytes.bytesize == CODE_BYTES + SIGNATURE_BYTES

    code = bytes.byteslice(0, CODE_BYTES)
    version, key_id = code.unpack("CC")
    raise Invalid unless version == VERSION

    key = keyring[key_id]
    raise Invalid unless key && valid_signature?(key, signed_message(code, event.id), bytes.byteslice(CODE_BYTES, SIGNATURE_BYTES))

    bytes_uuid(code.byteslice(2, 16))
  end

  # Key id => base64 DER SubjectPublicKeyInfo, for the scanner to verify with.
  def public_keys
    keyring.transform_values { |key| [ key.public_to_der ].pack("m0") }
  end

  def strip_prefix(value)
    text = value.to_s.strip
    text.downcase.start_with?(PREFIX) ? text[PREFIX.length..] : text
  end

  def keyring
    @keyring ||= load_keyring
  end

  # For tests, and for a key change without a restart.
  def keyring=(keys)
    @keyring = keys
  end

  def reset_keyring!
    @keyring = nil
  end

  def load_keyring
    keys = Rails.application.credentials.dig(:ticket_signing, :keys) || {}
    keys.to_h.each_with_object({}) do |(key_id, pem), ring|
      id = Integer(key_id.to_s)
      raise ArgumentError, "ticket_signing key ids must be 1-255" unless id.between?(1, 255)

      key = OpenSSL::PKey.read(pem.to_s)
      raise ArgumentError, "ticket_signing key #{id} is not a P-256 private key" unless key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name == CURVE && key.private?

      ring[id] = key
    end
  end

  def generate_key
    OpenSSL::PKey::EC.generate(CURVE)
  end

  # version | key id, then the event, then the registration.
  def signed_message(code, event_id)
    code.byteslice(0, 2) + uuid_bytes(event_id) + code.byteslice(2, 16)
  end

  # Deterministic (RFC 6979), so one registration always gets the same code:
  # a wallet pass is only pushed when its contents change, and a fresh random
  # signature on every render would make every pass look changed. OpenSSL
  # before 3.2 can't do that; there the signature is random but just as valid.
  def raw_signature(key, message)
    der = begin
      key.sign("SHA256", message, DETERMINISTIC)
    rescue OpenSSL::PKey::PKeyError
      key.sign("SHA256", message)
    end
    OpenSSL::ASN1.decode(der).value.map { |part| part.value.to_s(2).rjust(32, "\0") }.join
  end

  def valid_signature?(key, message, signature)
    r = OpenSSL::BN.new(signature.byteslice(0, 32), 2)
    s = OpenSSL::BN.new(signature.byteslice(32, 32), 2)
    der = OpenSSL::ASN1::Sequence.new([ OpenSSL::ASN1::Integer.new(r), OpenSSL::ASN1::Integer.new(s) ]).to_der
    key.verify("SHA256", der, message)
  rescue OpenSSL::PKey::PKeyError
    false
  end

  # RFC 4648 base32, no padding.
  def base32_encode(bytes)
    bits = bytes.unpack1("B*")
    bits += "0" * (-bits.length % 5)
    bits.scan(/.{5}/).map { |chunk| BASE32[chunk.to_i(2)] }.join
  end

  def base32_decode(text)
    return nil unless text.match?(/\A[A-Z2-7]+\z/)

    bits = text.each_char.map { |char| BASE32.index(char).to_s(2).rjust(5, "0") }.join
    [ bits[0, bits.length - (bits.length % 8)] ].pack("B*")
  end

  def uuid_bytes(uuid)
    hex = uuid.to_s.delete("-")
    raise ArgumentError, "not a uuid: #{uuid.inspect}" unless hex.match?(/\A\h{32}\z/)

    [ hex ].pack("H*")
  end

  def bytes_uuid(bytes)
    bytes.unpack1("H*").unpack("a8a4a4a4a12").join("-")
  end
end
