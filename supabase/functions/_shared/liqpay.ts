import { sha3_256 } from 'npm:js-sha3@0.9.3'

function toBase64(bytes: Uint8Array) {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

export function encodeLiqPayData(payload: Record<string, unknown>) {
  return toBase64(new TextEncoder().encode(JSON.stringify(payload)))
}

export function liqPaySignature(privateKey: string, data: string) {
  return toBase64(new Uint8Array(sha3_256.arrayBuffer(`${privateKey}${data}${privateKey}`)))
}

export function secureEqual(left: string, right: string) {
  let difference = left.length ^ right.length
  const length = Math.max(left.length, right.length)
  for (let index = 0; index < length; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0)
  }
  return difference === 0
}

export function decodeLiqPayData<T>(data: string): T {
  const binary = atob(data)
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0))
  return JSON.parse(new TextDecoder().decode(bytes)) as T
}
