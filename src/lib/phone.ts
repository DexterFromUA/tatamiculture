// Accept Ukrainian local numbers as well as international numbers.
export function normalizePhone(input: string): string | null {
  const compact = input.trim().replace(/[\s()-]/g, '')
  const international = /^0\d{9}$/.test(compact) ? '+38' + compact
    : /^380\d{9}$/.test(compact) ? '+' + compact : compact
  return /^\+[1-9]\d{7,14}$/.test(international) ? international : null
}

export function normalizeUkrainianPhone(input: string): string | null {
  const phone = normalizePhone(input)
  return phone && /^\+380[1-9]\d{8}$/.test(phone) ? phone : null
}

export function normalizeCheckoutPhone(input: string): string | null {
  const phone = normalizePhone(input)
  if (!phone?.startsWith('+380')) return phone
  return /^\+380(?:3[1-8]|4[13-8]|5[0-7]|6[1-9]|7[3-9]|8[1-59]|9[1-9])\d{7}$/.test(phone) ? phone : null
}

// Keep the country prefix while accepting local-number pastes and phone autofill.
export function ukrainianPhoneInput(input: string): string {
  const digits = input.replace(/\D/g, '')
  const subscriber = digits.startsWith('380') ? digits.slice(3)
    : digits.startsWith('0') ? digits.slice(1)
      : ['3', '38'].includes(digits) ? '' : digits
  return '+380' + subscriber
}
