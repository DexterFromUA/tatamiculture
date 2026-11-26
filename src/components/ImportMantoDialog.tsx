import { useId, useEffect, useRef, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { CenteredDialog } from './CenteredDialog'

export function ImportMantoDialog({ onClose, onImport }: {
  onClose: () => void
  onImport: (link: string, signal: AbortSignal) => Promise<void>
}) {
  const { t } = useTranslation()
  const titleId = useId()
  const [link, setLink] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const request = useRef<AbortController | null>(null)
  useEffect(() => () => request.current?.abort(), [])

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (request.current || !link.trim()) return
    const controller = new AbortController()
    request.current = controller
    setBusy(true)
    setError('')
    try {
      await onImport(link.trim(), controller.signal)
      if (!controller.signal.aborted) onClose()
    } catch (cause) {
      if (!controller.signal.aborted) {
        setError(cause instanceof Error ? cause.message : 'Could not read the Manto product. Check the link and try again.')
      }
    } finally {
      request.current = null
      if (!controller.signal.aborted) setBusy(false)
    }
  }

  return <CenteredDialog className="order-import-dialog" aria-labelledby={titleId} busy={busy} onClose={onClose}>
    <h2 id={titleId} tabIndex={-1} ref={heading => heading?.setAttribute('autofocus', '')}>{t('Import from Manto')}</h2>
    <form className="order-import-dialog__content" onSubmit={submit}>
      <label className="field">
        <span>{t('Manto product link')}</span>
        <input type="url" value={link} disabled={busy} required
          placeholder="https://www.mantoshop.eu/product-eng-…"
          onChange={event => { setLink(event.target.value); setError('') }} />
        <small className="muted">{t('Accepts links from mantoshop.eu and mantoshop.pl.')}</small>
      </label>
      {error && <div className="error" role="alert">{t(error)}</div>}
      <div className="confirmation-dialog__actions">
        <button type="button" className="btn btn--ghost" disabled={busy}
          onClick={event => event.currentTarget.closest('dialog')?.close()}>{t('Cancel')}</button>
        <button type="submit" className="btn" disabled={busy || !link.trim()}>
          {t(busy ? 'Importing product…' : 'Import product')}
        </button>
      </div>
    </form>
  </CenteredDialog>
}
