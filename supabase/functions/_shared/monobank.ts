export const monobankApi = 'https://api.monobank.ua/api/merchant'

export function monobankToken(testMode: boolean) {
  const live = Deno.env.get('MONOBANK_TOKEN')?.trim()
  if (!testMode) return live
  const test = Deno.env.get('MONOBANK_TEST_TOKEN')?.trim()
  return test && test !== live ? test : undefined
}
