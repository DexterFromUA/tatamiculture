// Read-only checks against the linked project's public API. Never prints credentials.
import { readFileSync } from 'node:fs'
import assert from 'node:assert/strict'
const values = Object.fromEntries(readFileSync(new URL('../.env.local', import.meta.url), 'utf8').split('\n').filter(line => /^VITE_SUPABASE_(URL|ANON_KEY)=/.test(line)).map(line => {
  const index = line.indexOf('=')
  return [line.slice(0, index), line.slice(index + 1).trim().replace(/^['"]|['"]$/g, '')]
}))
const url = values.VITE_SUPABASE_URL.replace(/\/$/, '')
const headers = { apikey: values.VITE_SUPABASE_ANON_KEY, Authorization: `Bearer ${values.VITE_SUPABASE_ANON_KEY}`, 'Content-Type': 'application/json' }
for (const table of ['order_events', 'order_financials', 'order_returns', 'customer_notifications']) {
  const response = await fetch(`${url}/rest/v1/${table}?select=*&limit=1`, { headers })
  assert.notEqual(response.status, 404, `${table} missing`)
  assert.ok([200, 401, 403].includes(response.status), `${table}: unexpected HTTP ${response.status}`)
  if (response.ok) assert.deepEqual(await response.json(), [], `Anonymous access leaked ${table}`)
  console.log(`${table}: anonymous access blocked`)
}
const response = await fetch(`${url}/rest/v1/rpc/receipt_events`, { method: 'POST', headers, body: JSON.stringify({ p_code: 'nonexistent-receipt-test' }) })
assert.equal(response.status, 200)
assert.deepEqual(await response.json(), [])
console.log('Unknown receipt returns no events')
