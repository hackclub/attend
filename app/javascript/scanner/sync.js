// Sends queued scans once the connection is back: oldest first, one at a
// time, backing off while the server stays out of reach.
//
// Every scan carries its client_scan_id, so sending one twice (two tabs, a
// response lost on the way back) records it once.
const RETRY_BASE_MS = 2000
const RETRY_MAX_MS = 60000
// While signed out there is nothing to gain from hammering the server.
const SESSION_RETRY_MS = 60000
const LOCK_NAME = "attend-scanner-sync"

export function retryDelay(failures) {
  const delay = Math.min(RETRY_MAX_MS, RETRY_BASE_MS * 2 ** Math.max(0, failures - 1))
  // Jitter, so a room of scanners doesn't retry in step.
  return Math.round(delay * (0.8 + Math.random() * 0.4))
}

// `scope` is the event and user this page scans for: only their scans are
// sent from here, since a scan is recorded under whoever is signed in.
export function createScanQueue({ store, api, scope, signal, onChange, onSynced }) {
  let records = []
  let syncing = false
  let sessionExpired = false
  let failures = 0
  let retryTimer = null

  const mine = (record) => record.eventId === scope.eventId && record.userId === scope.userId
  const byAge = (a, b) => String(a.clientScannedAt).localeCompare(String(b.clientScannedAt))

  function snapshot() {
    const ours = records.filter(mine).sort(byAge)
    return {
      queued: ours.filter((record) => record.status === "queued"),
      rejected: ours.filter((record) => record.status === "rejected"),
      elsewhere: records.filter((record) => !mine(record) && record.status === "queued").length,
      syncing,
      sessionExpired
    }
  }

  function changed() {
    if (!signal.aborted) onChange(snapshot())
  }

  async function load() {
    records = await store.all()
    changed()
  }

  async function enqueue(record) {
    const stored = { ...record, ...scope, status: "queued", attempts: 1 }
    await store.put(stored)
    records.push(stored)
    changed()
    schedule(retryDelay(++failures))
  }

  async function dismiss(clientScanId) {
    await store.remove(clientScanId)
    records = records.filter((record) => record.clientScanId !== clientScanId)
    changed()
  }

  async function discardQueued() {
    for (const record of snapshot().queued) await store.remove(record.clientScanId)
    records = records.filter((record) => !(mine(record) && record.status === "queued"))
    sessionExpired = false
    changed()
  }

  function schedule(delay) {
    clearTimeout(retryTimer)
    if (signal.aborted) return
    retryTimer = setTimeout(sync, delay)
  }

  async function sendAll() {
    // Re-read first: another tab may have sent or added scans since.
    records = await store.all()

    for (const record of snapshot().queued) {
      if (signal.aborted) return

      const result = await api.postScan({
        ...record.body,
        client_scan_id: record.clientScanId,
        client_scanned_at: record.clientScannedAt
      })

      if (result.outcome === "ok") {
        await store.remove(record.clientScanId)
        records = records.filter((other) => other.clientScanId !== record.clientScanId)
        failures = 0
        sessionExpired = false
        if (!signal.aborted) onSynced(record, result.data)
      } else if (result.outcome === "refused") {
        // The server understood and said no. Retrying can't change that, so
        // keep it where the operator will see it until they dismiss it.
        Object.assign(record, { status: "rejected", error: result.message, rejectedAt: new Date().toISOString() })
        await store.put(record)
        failures = 0
        sessionExpired = false
      } else if (result.outcome === "session") {
        // Not a verdict on the scan: it stays queued until someone signs in.
        sessionExpired = true
        schedule(SESSION_RETRY_MS)
        return
      } else {
        record.attempts = (record.attempts || 0) + 1
        await store.put(record)
        sessionExpired = false
        schedule(retryDelay(++failures))
        return
      }
      changed()
    }
  }

  async function sync() {
    clearTimeout(retryTimer)
    if (syncing || signal.aborted) return
    if (!snapshot().queued.length) return

    syncing = true
    changed()
    try {
      // One tab sends at a time where the browser can arrange it.
      if (navigator.locks?.request) {
        await navigator.locks.request(LOCK_NAME, { ifAvailable: true }, async (lock) => {
          if (lock) await sendAll()
          else schedule(retryDelay(1))
        })
      } else {
        await sendAll()
      }
    } catch (error) {
      console.error("Scan sync failed:", error)
      schedule(retryDelay(++failures))
    } finally {
      syncing = false
      changed()
    }
  }

  window.addEventListener("online", sync, { signal })
  window.addEventListener("online", changed, { signal })
  window.addEventListener("offline", changed, { signal })
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") sync()
  }, { signal })
  signal.addEventListener("abort", () => clearTimeout(retryTimer))

  return { load, enqueue, dismiss, discardQueued, sync, snapshot }
}
