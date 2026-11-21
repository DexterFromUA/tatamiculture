import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { encodeLiqPayData, legacyLiqPayKeys, liqPayKeys, liqPaySignature } from './liqpay.ts'
import { monobankApi, monobankToken } from './monobank.ts'

export type RefundOperation = {
  id: string
  amount: number
  currency: string
  provider: 'MONOBANK' | 'LIQPAY'
  reference: string
  payment_id: string | null
  payment_test_mode: boolean | null
}

export type RefundResult = { status: 'completed' | 'processing' | 'failed'; error?: string; absenceVerified?: true }

export type MonoCancellation = { extRef?: string; status?: string; amount?: number }
export type MonoInvoice = {
  invoiceId?: string; reference?: string; ccy?: number; amount?: number; status?: string; finalAmount?: number; cancelList?: MonoCancellation[]
}
type LiqPayInvoice = {
  order_id?: string; amount?: number | string; amount_return?: number | string; currency?: string
  payment_id?: string | number; result?: string; status?: string; wait_amount?: boolean | string
  wait_reserve_status?: string
}

const processing: RefundResult = { status: 'processing' }
const noRefundFound: RefundResult = { status: 'processing', absenceVerified: true }
const completed: RefundResult = { status: 'completed' }
const failed = (error: string): RefundResult => ({ status: 'failed', error })

async function readResult<T>(response: Response) {
  return await response.json() as T
}

function matchesMonoInvoice(invoice: MonoInvoice, operation: RefundOperation) {
  return invoice.invoiceId === operation.reference && invoice.amount === operation.amount &&
    operation.currency === 'UAH' && invoice.ccy === 980
}

function monoCancellationResult(invoice: MonoInvoice, operation: RefundOperation): RefundResult {
  const cancellation = invoice.cancelList?.find(item => item.extRef === operation.id)
  if (cancellation?.status === 'failure') return failed('The payment provider rejected the refund')
  if (cancellation?.status === 'success' && cancellation.amount === operation.amount) return completed
  if (!cancellation && invoice.status === 'reversed' && invoice.finalAmount === 0) return completed
  if (invoice.status === 'success' && (invoice.finalAmount ?? invoice.amount) === operation.amount &&
    !invoice.cancelList?.some(item => item.status !== 'failure')) return noRefundFound
  return processing
}

async function refundMonobank(operation: RefundOperation, check: boolean): Promise<RefundResult> {
  const token = monobankToken(false)
  if (!token) return check ? processing : failed('The payment provider is not configured')
  const invoice = await fetch(`${monobankApi}/invoice/status?invoiceId=${encodeURIComponent(operation.reference)}`, {
    headers: { 'X-Token': token }, signal: AbortSignal.timeout(8000),
  }).then(response => response.ok ? readResult<MonoInvoice>(response) : null).catch(() => null)
  if (!invoice) return check ? processing : failed('Could not verify the original payment')
  if (!matchesMonoInvoice(invoice, operation)) return check ? processing : failed('The original payment does not match the order')
  if (check) return monoCancellationResult(invoice, operation)
  if (invoice.status !== 'success' || (invoice.finalAmount ?? invoice.amount) !== operation.amount ||
      invoice.cancelList?.some(item => item.status !== 'failure')) {
    return failed('The payment has already been refunded or cannot be refunded automatically')
  }
  const response = await fetch(`${monobankApi}/invoice/cancel`, {
    method: 'POST', headers: { 'X-Token': token, 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(10000),
    body: JSON.stringify({ invoiceId: operation.reference, extRef: operation.id }),
  })
  if ([400, 403, 404].includes(response.status)) return failed('The payment provider rejected the refund')
  if (!response.ok) return processing
  const { status } = await readResult<{ status?: string }>(response)
  if (status === 'success') return completed
  return status === 'failure' ? failed('The payment provider rejected the refund') : processing
}

function matchesLiqPayInvoice(invoice: LiqPayInvoice, operation: RefundOperation) {
  return invoice.order_id === operation.reference && invoice.currency === operation.currency &&
    (!operation.payment_id || String(invoice.payment_id) === operation.payment_id) &&
    Math.round(Number(invoice.amount) * 100) === operation.amount
}

function waitingForLiqPayFunds(invoice: LiqPayInvoice) {
  return invoice.wait_amount === true || invoice.wait_amount === 'true'
}

async function refundLiqPay(operation: RefundOperation, check: boolean): Promise<RefundResult> {
  const keys = operation.payment_test_mode === null ? legacyLiqPayKeys() : liqPayKeys(false)
  if (!keys || keys.publicKey.startsWith('sandbox_')) return check ? processing : failed('The payment provider is not configured')
  const send = async (action: 'status' | 'refund', fields = {}) => {
    const data = encodeLiqPayData({ version: '3', public_key: keys.publicKey, order_id: operation.reference, action, ...fields })
    return await fetch('https://www.liqpay.ua/api/request', {
      method: 'POST', body: new URLSearchParams({ data, signature: await liqPaySignature(keys.privateKey, data) }),
      signal: AbortSignal.timeout(10000),
    })
  }
  const invoice = await send('status').then(response => response.ok ? readResult<LiqPayInvoice>(response) : null).catch(() => null)
  if (!invoice) return check ? processing : failed('Could not verify the original payment')
  if (!matchesLiqPayInvoice(invoice, operation)) return check ? processing : failed('The original payment does not match the order')
  if (check) {
    if (invoice.status === 'reversed' && !waitingForLiqPayFunds(invoice) &&
      (invoice.amount_return == null || Math.round(Number(invoice.amount_return) * 100) === operation.amount)) return completed
    if (invoice.result === 'ok' && invoice.status === 'success' && !waitingForLiqPayFunds(invoice) &&
      !invoice.wait_reserve_status && Number(invoice.amount_return ?? 0) === 0) return noRefundFound
    return processing
  }
  if (invoice.status !== 'success' || Number(invoice.amount_return ?? 0) !== 0) {
    return failed('The payment has already been refunded or cannot be refunded automatically')
  }
  const response = await send('refund', { amount: operation.amount / 100 })
  if (!response.ok) return processing
  const refund = await readResult<LiqPayInvoice>(response)
  if (refund.result === 'error' || refund.status === 'failure' || refund.status === 'error') {
    return failed('The payment provider rejected the refund')
  }
  if (refund.status === 'reversed' && refund.result === 'ok' && !waitingForLiqPayFunds(refund) &&
      (!operation.payment_id || String(refund.payment_id) === operation.payment_id)) return completed
  return processing
}

export async function reconcileOrderRefund(db: SupabaseClient, provider: string, reference: string, invoice?: MonoInvoice) {
  const { data, error } = await db.rpc('pending_order_cancellation_refund', {
    p_provider: provider, p_reference: reference,
  })
  if (error) throw error
  const operation = data as RefundOperation | null
  if (!operation) return false
  const outcome = invoice && matchesMonoInvoice(invoice, operation)
    ? monoCancellationResult(invoice, operation)
    : await refundOrderPayment(operation, true)
  if (outcome.status !== 'processing') {
    const { error: finishError } = await db.rpc('finish_order_cancellation_refund', {
      p_id: operation.id, p_status: outcome.status, p_error: outcome.error ?? null,
    })
    if (finishError) throw finishError
  }
  return true
}

export async function refundOrderPayment(operation: RefundOperation, check: boolean): Promise<RefundResult> {
  try {
    if (operation.provider === 'MONOBANK') return await refundMonobank(operation, check)
    if (operation.provider === 'LIQPAY') return await refundLiqPay(operation, check)
    return check ? processing : failed('Automatic refund is unavailable for this order')
  } catch {
    // A timeout or malformed response may have occurred after money movement.
    // The operation must remain locked while its outcome is checked.
    return processing
  }
}
