import test from 'node:test'
import assert from 'node:assert/strict'
import { listenForSmsCode } from '../src/lib/smsCode.ts'

function browser(get) {
  const previous = ['window', 'navigator'].map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)])
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { isSecureContext: true, OTPCredential: {}, setTimeout, clearTimeout } })
  Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { credentials: { get } } })
  return () => previous.forEach(([key, descriptor]) => descriptor ? Object.defineProperty(globalThis, key, descriptor) : delete globalThis[key])
}

test('WebOTP fills a six-digit code without submitting the form', async () => {
  let options
  const restore = browser(async value => { options = value; return { code: '123456' } })
  try {
    const codes = []
    const stop = listenForSmsCode(code => codes.push(code))
    await new Promise(resolve => setImmediate(resolve))
    assert.deepEqual(codes, ['123456'])
    assert.deepEqual(options.otp.transport, ['sms'])
    stop()
    assert.equal(options.signal.aborted, true)
  } finally { restore() }
})

test('leaving the code step or requesting another SMS discards a late result', async () => {
  let deliver
  const restore = browser(() => new Promise(resolve => { deliver = resolve }))
  try {
    const codes = []
    const stop = listenForSmsCode(code => codes.push(code))
    stop()
    deliver({ code: '654321' })
    await new Promise(resolve => setImmediate(resolve))
    assert.deepEqual(codes, [])
  } finally { restore() }
})

test('a denied WebOTP prompt leaves manual code entry available', async () => {
  const restore = browser(async () => { throw new Error('NotAllowedError') })
  try {
    const stop = listenForSmsCode(() => assert.fail('No code was granted'))
    await new Promise(resolve => setImmediate(resolve))
    stop()
  } finally { restore() }
})
