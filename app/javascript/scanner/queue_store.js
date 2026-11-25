// Scans that couldn't be sent, kept in IndexedDB so they survive a reload, a
// closed tab or a flat battery.
//
// A stored scan is only what it takes to send it again: the code that was
// read (a participant id or badge token), the scan point, and when. No name,
// status or anything else about the person is ever written to the device;
// that only exists on the server.
const DATABASE = "attend-scanner"
const STORE = "scans"

function request(idbRequest) {
  return new Promise((resolve, reject) => {
    idbRequest.onsuccess = () => resolve(idbRequest.result)
    idbRequest.onerror = () => reject(idbRequest.error)
  })
}

// Resolves to a store, or rejects where IndexedDB is missing or refused (some
// private browsing modes), in which case nothing can be queued.
export async function openQueueStore() {
  if (!("indexedDB" in window)) throw new Error("IndexedDB is not available")

  const opening = indexedDB.open(DATABASE, 1)
  opening.onupgradeneeded = () => {
    opening.result.createObjectStore(STORE, { keyPath: "clientScanId" })
  }
  const database = await request(opening)
  // Another tab upgrading the schema must not be blocked by this one.
  database.onversionchange = () => database.close()

  const store = (mode) => database.transaction(STORE, mode).objectStore(STORE)

  return {
    all: () => request(store("readonly").getAll()),
    put: (record) => request(store("readwrite").put(record)),
    remove: (clientScanId) => request(store("readwrite").delete(clientScanId)),
    close: () => database.close()
  }
}
