import assert from "node:assert/strict"
import test from "node:test"

import { INVALID_TICKET, createTicketVerifier, parseCheckinCode } from "../../app/javascript/scanner/ticket.js"

// Signed by app/lib/checkin_code.rb with a throwaway test key (id 7), so these
// prove the browser accepts exactly what the server issues. The ids are made up.
const PUBLIC_KEY = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEDMGrzwLJmvAf9CaURz5Y2aIFiKc2FxfG+yMDnQWOZa213pITd/f5LHlfiNo6Q6+D5l2SNe5m6+czg0RJ4Y416Q=="
const EVENT_ID = "11111111-2222-4333-8444-555555555555"
const REGISTRATION_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
const TOKEN = "T.AED2VKVKVK53WTGMRXO653XO53XO5Z3XVB66Q34V2V72SPD3JRKHN4OXBNR25I7BTJUMJXLV5SVSFKINXVAFGF3TRFORE5QNYCF2XWIF6OCUGZV3LXX3WPJ5DBNJZOPQ3ZCA"
// The same registration, signed for another event.
const OTHER_EVENT_TOKEN = "T.AED2VKVKVK53WTGMRXO653XO53XO4IKY2AFTZRK2Z72DCBHMEVNYOORP3ZHFW2N5D5PWY57EAJ4KV2MUWDPM2A3B5YHXJJ4PAC373WKPO26USHLMVTOD6BAQWFWCWSSSFKTQ"

const BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

function base32(bytes) {
  let bits = ""
  for (const byte of bytes) bits += byte.toString(2).padStart(8, "0")
  bits += "0".repeat((5 - (bits.length % 5)) % 5)
  return bits.match(/.{5}/g).map((chunk) => BASE32[parseInt(chunk, 2)]).join("")
}

function bytesOf(token) {
  const bits = [ ...token.slice(2) ].map((char) => BASE32.indexOf(char).toString(2).padStart(5, "0")).join("")
  return Uint8Array.from(bits.slice(0, bits.length - (bits.length % 8)).match(/.{8}/g), (byte) => parseInt(byte, 2))
}

function tamper(token, index) {
  const bytes = bytesOf(token)
  bytes[index] ^= 0x01
  return `T.${base32(bytes)}`
}

const verifier = (overrides = {}) => createTicketVerifier({ keys: { 7: PUBLIC_KEY }, eventId: EVENT_ID, ...overrides })

test("reads a signed code, with or without the deep link, in either case", () => {
  for (const text of [ TOKEN, `ATTEND://CHECKIN/${TOKEN}`, `  attend://checkin/${TOKEN.toLowerCase()}\n` ]) {
    const code = parseCheckinCode(text)
    assert.equal(code.kind, "signed", text)
    assert.equal(code.token, TOKEN)
    assert.equal(code.keyId, "7")
    assert.equal(code.participantEventId, REGISTRATION_ID)
  }
})

test("reads old codes and typed ids as plain, and broken signed ones as malformed", () => {
  assert.deepEqual(parseCheckinCode(`attend://checkin/${REGISTRATION_ID}`), { kind: "plain", id: REGISTRATION_ID })
  assert.deepEqual(parseCheckinCode("AAAAAAAA"), { kind: "plain", id: "AAAAAAAA" })
  for (const broken of [ "T.", "T.!!!", `T.${"A".repeat(20)}`, `T.${"1".repeat(132)}`, `T.${base32(new Uint8Array(82).fill(2))}` ]) {
    assert.equal(parseCheckinCode(broken).kind, "malformed", broken)
  }
})

test("accepts a ticket the server signed for this event", async () => {
  assert.deepEqual(await verifier()(parseCheckinCode(TOKEN)), { verdict: "valid", participantEventId: REGISTRATION_ID })
})

test("turns away a ticket signed for another event", async () => {
  assert.deepEqual(await verifier()(parseCheckinCode(OTHER_EVENT_TOKEN)), { verdict: "invalid", reason: "forged" })
})

test("turns away a ticket edited after signing, in the id or the signature", async () => {
  const verify = verifier()
  for (const index of [ 2, 10, 17, 18, 50, 81 ]) {
    assert.deepEqual(await verify(parseCheckinCode(tamper(TOKEN, index))), { verdict: "invalid", reason: "forged" }, `byte ${index}`)
  }
})

test("turns away a ticket signed with a key that isn't Attend's", async () => {
  const { privateKey } = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [ "sign", "verify" ])
  const code = bytesOf(TOKEN).subarray(0, 18)
  const event = Uint8Array.from(EVENT_ID.replace(/-/g, "").match(/../g), (pair) => parseInt(pair, 16))
  const message = new Uint8Array([ ...code.subarray(0, 2), ...event, ...code.subarray(2) ])
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, message))
  const forged = `T.${base32(new Uint8Array([ ...code, ...signature ]))}`

  assert.deepEqual(await verifier()(parseCheckinCode(forged)), { verdict: "invalid", reason: "forged" })
})

test("flags a genuine ticket whose registration was withdrawn or rejected", async () => {
  const verify = verifier({ cancelled: [ REGISTRATION_ID.toUpperCase() ] })
  assert.deepEqual(await verify(parseCheckinCode(TOKEN)), { verdict: "cancelled", participantEventId: REGISTRATION_ID })
})

test("leaves what it can't check to the server", async () => {
  assert.deepEqual(await verifier()(parseCheckinCode(REGISTRATION_ID)), { verdict: "unverified" })
  // A key this page wasn't given, as after a key change.
  assert.deepEqual(await verifier({ keys: {} })(parseCheckinCode(TOKEN)), { verdict: "unverified" })
  // No WebCrypto at all.
  assert.deepEqual(await verifier({ subtle: null })(parseCheckinCode(TOKEN)), { verdict: "unverified" })
})

test("calls a damaged code invalid without trying to verify it", async () => {
  const verify = verifier({ subtle: { verify: () => assert.fail("should not verify"), importKey: () => assert.fail("should not import") } })
  assert.deepEqual(await verify(parseCheckinCode("T.!!!")), { verdict: "invalid", reason: "damaged" })
  assert.ok(INVALID_TICKET.damaged && INVALID_TICKET.forged)
})
