// Keep the URL to the filters that are applied: no "flag=&group_id=".
// Call from a form's `formdata` event. FormData#delete drops every entry with a
// name, so rebuild the list instead: a blank `roles[]=` must not take the
// selected `roles[]=a` with it.
export function dropBlankFields(formData) {
  const entries = [...formData]
  for (const name of new Set(entries.map(([ name ]) => name))) formData.delete(name)
  for (const [ name, value ] of entries) {
    if (value !== "") formData.append(name, value)
  }
}
