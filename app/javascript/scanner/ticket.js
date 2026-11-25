// Reads what a QR code says, and checks a signed one on the device, so a
// forged code is turned away even with no connection. The format and the
// keys come from the server (app/lib/checkin_code.rb); only the server can
// sign, this side can only check.
//
// A signed code is `ATTEND://CHECKIN/T.<base32>`, decoding to
//
//   version (1) | key id (1) | participant_event id (16) | signature (64)
//
// with an Ed25519 signature over
//
//   version (1) | key id (1) | event id (16) | participant_event id (16)
//
// The event id isn't in the code: the scanner supplies its own, so a ticket
// for another event fails the signature like a forged one.

const PREFIX = "attend://checkin/"
const SIGNED_MARKER = "T."
const VERSION = 1
const CODE_BYTES = 18
const SIGNATURE_BYTES = 64
const BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

function base32Decode(text) {
  if (!/^[A-Z2-7]+$/.test(text)) return null
  let bits = ""
  for (const char of text) bits += BASE32.indexOf(char).toString(2).padStart(5, "0")
  const bytes = new Uint8Array(Math.floor(bits.length / 8))
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(bits.slice(i * 8, i * 8 + 8), 2)
  return bytes
}

function fromBase64(text) {
  return Uint8Array.from(atob(text), (char) => char.charCodeAt(0))
}

function uuid(bytes) {
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

function uuidBytes(id) {
  const hex = String(id).replace(/-/g, "")
  if (!/^[0-9a-f]{32}$/i.test(hex)) return null
  return Uint8Array.from(hex.match(/../g), (pair) => parseInt(pair, 16))
}

// What the scanner reads off a code:
//
//   { kind: "signed", token, keyId, participantEventId, code, signature }
//   { kind: "malformed", token }  shaped like a signed code, but isn't one
//   { kind: "plain", id }         an old unsigned code, or a typed id
export function parseCheckinCode(text) {
  const value = String(text || "").trim()
  const rest = value.toLowerCase().startsWith(PREFIX) ? value.slice(PREFIX.length) : value
  if (!rest.toUpperCase().startsWith(SIGNED_MARKER)) return { kind: "plain", id: rest }

  const token = rest.toUpperCase()
  const bytes = base32Decode(token.slice(SIGNED_MARKER.length))
  if (!bytes || bytes.length !== CODE_BYTES + SIGNATURE_BYTES || bytes[0] !== VERSION) return { kind: "malformed", token }

  return {
    kind: "signed",
    token,
    keyId: String(bytes[1]),
    participantEventId: uuid(bytes.subarray(2, 18)),
    code: bytes.slice(0, CODE_BYTES),
    signature: bytes.slice(CODE_BYTES)
  }
}

// `keys` is { keyId: base64 SPKI } and `cancelled` the registration ids whose
// tickets no longer count, both from the page config. `verify` resolves to
//
//   { verdict: "valid", participantEventId }
//   { verdict: "cancelled", participantEventId }  genuine, but withdrawn or rejected
//   { verdict: "invalid", reason }                 "damaged", or "forged": not
//                                                  signed by Attend for this event
//   { verdict: "unverified" }                      can't be checked here (see below)
//
// An unsigned code is "unverified": it can only be looked up online. So is a
// signed one whose key this page wasn't given, which happens when the key
// changed after the page was saved, and any signed one on a browser without
// Ed25519 in WebCrypto (Chrome before 137, Safari before 17); the server
// still checks those.
export function createTicketVerifier({ keys = {}, eventId, cancelled = [], subtle = globalThis.crypto?.subtle } = {}) {
  const imported = new Map()
  const cancelledIds = new Set(cancelled.map((id) => String(id).toLowerCase()))
  const event = uuidBytes(eventId)

  function importKey(keyId) {
    if (!imported.has(keyId)) {
      imported.set(keyId, subtle.importKey("spki", fromBase64(keys[keyId]), { name: "Ed25519" }, false, [ "verify" ]))
    }
    return imported.get(keyId)
  }

  return async function verify(ticket) {
    if (ticket.kind === "plain") return { verdict: "unverified" }
    if (ticket.kind === "malformed") return { verdict: "invalid", reason: "damaged" }
    if (!subtle || !event || !keys[ticket.keyId]) return { verdict: "unverified" }

    const message = new Uint8Array(2 + 16 + 16)
    message.set(ticket.code.subarray(0, 2), 0)
    message.set(event, 2)
    message.set(ticket.code.subarray(2), 18)

    let genuine = false
    try {
      genuine = await subtle.verify({ name: "Ed25519" }, await importKey(ticket.keyId), ticket.signature, message)
    } catch (error) {
      console.warn("Couldn't check this ticket's signature:", error)
      return { verdict: "unverified" }
    }
    if (!genuine) return { verdict: "invalid", reason: "forged" }
    if (cancelledIds.has(ticket.participantEventId)) return { verdict: "cancelled", participantEventId: ticket.participantEventId }

    return { verdict: "valid", participantEventId: ticket.participantEventId }
  }
}

export const INVALID_TICKET = {
  damaged: "This QR code is damaged or isn't an Attend ticket.",
  forged: "This ticket wasn't issued by Attend for this event. It may be fake, or for a different event."
}
