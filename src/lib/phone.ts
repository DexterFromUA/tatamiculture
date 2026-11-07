// Accept Ukrainian local numbers as well as international numbers.
export function normalizePhone(input: string): string | null {
  const compact = input.trim().replace(/[\s()-]/g, '')
  const international = /^0\d{9}$/.test(compact) ? '+38' + compact
    : /^380\d{9}$/.test(compact) ? '+' + compact : compact
  return /^\+[1-9]\d{7,14}$/.test(international) ? international : null
}
