import { DirectUpload } from "@rails/activestorage"

// Uploads a file straight from the browser to storage (Active Storage's direct
// upload: Rails makes the blob and a signed PUT URL, the browser sends the
// bytes), so the form request that follows carries only the blob's signed id
// and never waits on the bucket.
//
// Resolves to that signed id, or to null when the upload couldn't happen for
// any reason (no URL, storage CORS not set up, a network error). Callers fall
// back to posting the file with the form, so a null is never fatal.
export function directUpload(file, url) {
  if (!file || !url) return Promise.resolve(null)

  return new Promise((resolve) => {
    try {
      new DirectUpload(file, url).create((error, blob) => {
        resolve(error || !blob ? null : blob.signed_id)
      })
    } catch {
      resolve(null)
    }
  })
}
