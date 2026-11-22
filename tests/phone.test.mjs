import test from 'node:test'
import assert from 'node:assert/strict'
import { normalizeCheckoutPhone, normalizePhone, normalizeUkrainianPhone, ukrainianPhoneInput } from '../src/lib/phone.ts'

test('SMS login requires a complete Ukrainian number', () => {
  for (const value of ['+380', '+38067123456', '+3806712345678', '+380067123456', '+447911123456']) {
    assert.equal(normalizeUkrainianPhone(value), null, value)
  }
  for (const value of ['0671234567', '380671234567', '+380 (67) 123-45-67']) {
    assert.equal(normalizeUkrainianPhone(value), '+380671234567')
  }
  assert.equal(normalizePhone('+447911123456'), '+447911123456', 'CRM international normalization remains supported')
})

test('phone entry preserves the prefix and supports pastes without silently truncating long numbers', () => {
  assert.equal(ukrainianPhoneInput(''), '+380')
  assert.equal(ukrainianPhoneInput('+38'), '+380')
  assert.equal(ukrainianPhoneInput('067 123-45-67'), '+380671234567')
  assert.equal(ukrainianPhoneInput('+380 (67) 123-45-67'), '+380671234567')
  assert.equal(normalizeUkrainianPhone(ukrainianPhoneInput('+3806712345678')), null)
})

test('checkout validates the length and Ukrainian dialing prefix before normalizing a phone', () => {
  for (const [input, expected] of [
    ['067 123 45 67', '+380671234567'],
    ['380671234567', '+380671234567'],
    ['+380 (79) 012-34-56', '+380790123456'],
    ['+380 (44) 123-45-67', '+380441234567'],
    ['+44 7911 123456', '+447911123456'],
  ]) assert.equal(normalizeCheckoutPhone(input), expected, input)

  for (const input of ['1234567890', '+380123456789', '+380000000000', '+38067123456', '+3806712345678', '+380 67 abc 45 67']) {
    assert.equal(normalizeCheckoutPhone(input), null, input)
  }
})
