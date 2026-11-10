export const invalidTtnRecipientName = 'Enter the recipient’s surname and first name in Cyrillic.'

const namePart = /^\p{Script=Cyrillic}+(?:['-]\p{Script=Cyrillic}+)*$/u

export function parseTtnRecipientName(value: unknown) {
  if (typeof value !== 'string') return null
  const parts = value.normalize('NFC').replace(/[’ʼ]/g, "'").trim().split(/\s+/)
  if (parts.length < 2 || !parts.every(part => namePart.test(part))) return null

  const [lastName, firstName, ...middleNames] = parts
  return { lastName, firstName, middleName: middleNames.join(' ') }
}
