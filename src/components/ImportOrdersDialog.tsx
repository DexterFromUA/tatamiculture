import { useId, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { downloadCsv } from '../lib/crm'
import { createCrmOrder } from '../lib/crmOrder'
import { formatPrice } from '../lib/format'
import { OrderImportReadError, orderImportRequiredColumns, orderImportTemplate, prepareOrderImport, readOrderImportCsv, readOrderImportFile, type OrderImport } from '../lib/orderImport'
import { SupabaseError, supabaseRequest } from '../lib/supabase'
import type { Store } from '../types'
import { CenteredDialog } from './CenteredDialog'

export function ImportOrdersDialog({ store, token, onClose, onImported }: {
  store: Store
  token: string
  onClose: () => void
  onImported: (count: number) => void
}) {
  const { t, i18n } = useTranslation()
  const titleId = useId()
  const [link, setLink] = useState('')
  const [file, setFile] = useState<File | null>(null)
  const [preview, setPreview] = useState<OrderImport | null>(null)
  const [results, setResults] = useState<Record<string, { error?: string }>>({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const orders = preview?.orders ?? []
  const created = orders.filter(order => results[order.requestId] && !results[order.requestId].error).length
  const attempted = Object.keys(results).length > 0
  const currency = (amount: number) => formatPrice(amount / 100, store.currency)

  const selectFile = (next: File) => {
    setFile(next)
    setLink('')
    setError('')
  }

  const readSource = async () => {
    if (file) return readOrderImportFile(file)
    const { csv } = await supabaseRequest<{ csv: string }>('/functions/v1/crm-import-sheet', {
      method: 'POST', token, signal: AbortSignal.timeout(20000),
      body: JSON.stringify({ storeId: store.id, link: link.trim() }),
    })
    return readOrderImportCsv(csv)
  }

  const inspect = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (busy || (!file && !link.trim())) return
    setBusy(true)
    setError('')
    try {
      const [sheet, catalog] = await Promise.all([readSource(), api.getProducts(store.id, token)])
      const url = file ? null : new URL(link)
      const source = file ? ['file', file.name] : ['sheet', url!.pathname.split('/d/')[1].replace(/\/(edit|view|export|pubhtml|pub)\/?$/, ''),
        url!.searchParams.get('gid') ?? new URLSearchParams(url!.hash.slice(1)).get('gid') ?? '0']
      setResults({})
      setPreview(await prepareOrderImport(sheet, catalog, i18n.resolvedLanguage, [store.id, ...source], ids =>
        supabaseRequest<string[]>('/rest/v1/rpc/existing_import_orders', { method: 'POST', token,
          body: JSON.stringify({ p_store: store.id, p_ids: ids }) })))
    } catch (cause) {
      setError(cause instanceof SupabaseError || cause instanceof OrderImportReadError
        ? cause.message : 'Could not read the spreadsheet.')
    } finally {
      setBusy(false)
    }
  }

  const save = async () => {
    if (busy || !preview || preview.issues.length) return
    setBusy(true)
    let saved = 0
    for (const order of orders) {
      const result = results[order.requestId]
      if (result && !result.error) continue
      try {
        await createCrmOrder(store.id, token, order)
        setResults(current => ({ ...current, [order.requestId]: {} }))
        saved++
      } catch (cause) {
        const message = cause instanceof SupabaseError ? cause.message : 'Could not save this order. Try again.'
        setResults(current => ({ ...current, [order.requestId]: { error: message } }))
        if (!(cause instanceof SupabaseError) || ![400, 409].includes(cause.status)) break
      }
    }
    if (saved) onImported(saved)
    setBusy(false)
  }

  return <CenteredDialog className="order-import-dialog" aria-labelledby={titleId} busy={busy} onClose={onClose}>
    <h2 id={titleId}>{t('Import orders')}</h2>
    {!preview ? <form className="order-import-dialog__content" onSubmit={event => void inspect(event)}>
      <label className="field">
        <span>{t('Google Sheets link')}</span>
        <input type="url" placeholder="https://docs.google.com/spreadsheets/…" value={link} disabled={busy}
          onChange={event => { setLink(event.target.value); setFile(null); setError('') }} />
        <small className="muted">{t('The link must allow viewing without signing in. For private sheets, upload the file.')}</small>
      </label>

      <label className="product-photo-upload order-import-dialog__upload"
        onDragOver={event => event.preventDefault()}
        onDrop={event => {
          event.preventDefault()
          if (!busy && event.dataTransfer.files.length === 1) selectFile(event.dataTransfer.files[0])
          else if (!busy && event.dataTransfer.files.length > 1) setError('Choose one spreadsheet file.')
        }}>
        <input className="sr-only" type="file" accept=".csv,.xlsx" disabled={busy}
          onChange={event => {
            if (event.target.files?.[0]) selectFile(event.target.files[0])
            event.target.value = ''
          }} />
        <span className="product-photo-upload__icon" aria-hidden="true">＋</span>
        <span className="product-photo-upload__copy">
          <strong>{file?.name ?? t('Upload a spreadsheet')}</strong>
          <small>{t('CSV or XLSX · up to 5 MB · first sheet for XLSX')}</small>
        </span>
        <span className="product-photo-upload__action" aria-hidden="true">{t('Choose file')}</span>
      </label>

      <div className="order-import-dialog__guide">
        <div className="order-import-dialog__guide-head">
          <strong>{t('Spreadsheet format')}</strong>
          <button type="button" className="text-btn"
            onClick={() => downloadCsv('order-import-template.csv', orderImportTemplate)}>{t('Download CSV template')}</button>
        </div>
        <small>{t('Put column headers in the first row. Use one row per item.')}</small>
        <small>{t('Required columns')} <code>{orderImportRequiredColumns.join(', ')}</code></small>
        <small>{t('Use sku or product to identify each item. When matching by product name, add size if there are multiple variants.')}</small>
        <small>{t('Repeat order_id 101 on two rows to put both items in one order. With a blank order_id, each row is a separate order. The note column is optional.')}</small>
      </div>
      {error && <div className="error" role="alert">{t(error)}</div>}
      <div className="confirmation-dialog__actions">
        <button type="button" className="btn btn--ghost" disabled={busy}
          onClick={event => event.currentTarget.closest('dialog')?.close()}>{t('Cancel')}</button>
        <button type="submit" className="btn" disabled={busy || (!link.trim() && !file)}>
          {t(busy ? 'Reading spreadsheet…' : 'Preview orders')}
        </button>
      </div>
    </form> : <div className="order-import-dialog__content">
      {!!preview.skipped?.length && <details>
        <summary>{t('Already imported: {{count}}', { count: preview.skipped.length })}</summary>
        <ul>{preview.skipped.map(({ row, label }) => <li key={row}>{t('Row {{row}}', { row })}{label && ' · #' + label}</li>)}</ul>
      </details>}
      {preview.issues.length > 0 ? <div className="order-import-dialog__issues" role="alert">
        <strong>{t('Fix these rows in the spreadsheet and load it again.')}</strong>
        <ul className="confirmation-dialog__details">
          {preview.issues.map(({ row, message, value }, index) => <li key={index}>
            {row && <strong>{t('Row {{row}}', { row })} · </strong>}{t(message)}{value && <> · {value}</>}
          </li>)}
        </ul>
      </div> : <>
        <div className="order-import-dialog__summary">
          <div><strong>{t('Orders')}: {orders.length}</strong><small className="muted">{t('Payment on delivery')}</small></div>
          <strong>{currency(orders.reduce((sum, order) => sum + order.total, 0))}</strong>
        </div>
        <ul className="order-import-dialog__orders">
          {orders.map(order => {
            const result = results[order.requestId]
            return <li key={order.requestId}>
              <div className="order-import-dialog__order-head">
                <strong>{order.label ? `#${order.label} · ` : ''}{order.customer.name}</strong>
                <strong>{currency(order.total)}</strong>
              </div>
              <small className="muted">{order.customer.phone} · {order.delivery.city} · {order.delivery.address}</small>
              {order.items.map(item => <small key={item.variantId}>{item.name} × {item.quantity}</small>)}
              {order.note && <small className="muted">{order.note}</small>}
              {result && <small className={result.error ? 'error' : 'muted'}>{t(result.error ?? 'Order created')}</small>}
            </li>
          })}
        </ul>
        {attempted && <div role="status">{t('Orders created: {{created}} of {{total}}', { created, total: orders.length })}</div>}
      </>}
      <form method="dialog" className="confirmation-dialog__actions">
        {!attempted && <button type="button" className="btn btn--ghost" disabled={busy}
          onClick={() => setPreview(null)}>{t('Back to spreadsheet')}</button>}
        <button type="submit" className={created === orders.length && attempted ? 'btn' : 'btn btn--ghost'} disabled={busy}>
          {t(attempted ? 'Close' : 'Cancel')}
        </button>
        {!preview.issues.length && created < orders.length && <button type="button" className="btn" disabled={busy}
          onClick={() => void save()}>{t(busy ? 'Importing orders…' : attempted ? 'Retry remaining orders' : 'Import orders')}</button>}
      </form>
    </div>}
  </CenteredDialog>
}
