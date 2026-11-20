import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { agreement, agreementVersion, seller } from '../src/content/agreement.ts'
import { agreementServices } from '../src/content/agreementServices.ts'

test('the archived agreement is exactly the version presented to the registering user', () => {
  const migration = readFileSync(new URL('../supabase/migrations/20261120150000_registration_agreement.sql', import.meta.url), 'utf8')
  const archived = migration.match(/\$agreement\$([\s\S]*?)\$agreement\$/)?.[1]
  assert.ok(archived, 'The published agreement must be archived')
  assert.deepEqual(JSON.parse(archived), { seller, agreement, services: agreementServices }, 'Publish text changes as a new agreement version')
  assert.ok(migration.includes(`values ('${agreementVersion}',`))
})
