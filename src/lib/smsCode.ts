// Browsers without WebOTP continue to use autocomplete="one-time-code" or manual entry.
export function listenForSmsCode(onCode: (code: string) => void): () => void {
  if (!window.isSecureContext || !('OTPCredential' in window) || !navigator.credentials) return () => {}
  const controller = new AbortController()
  const timeout = window.setTimeout(() => controller.abort(), 120000)
  const options: CredentialRequestOptions & { otp: { transport: ['sms'] } } = {
    otp: { transport: ['sms'] }, signal: controller.signal,
  }
  void navigator.credentials.get(options).then(credential => {
    const code = (credential as (Credential & { code?: string }) | null)?.code
    if (!controller.signal.aborted && code && /^\d{6}$/.test(code)) onCode(code)
  }).catch(() => { /* Denial, timeout, and unsupported browsers leave manual entry available. */ })
    .finally(() => window.clearTimeout(timeout))
  return () => { controller.abort(); window.clearTimeout(timeout) }
}
