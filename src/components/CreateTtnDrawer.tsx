import { useEffect, useId, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { createTtn, defaultParcelDescription, getTtnPreview, type TtnShipment } from '../lib/ttn'
import { useDrawer } from '../lib/useDrawer'
import { invalidTtnRecipientName, parseTtnRecipientName } from '../../supabase/functions/_shared/ttn-recipient.ts'

export function CreateTtnDrawer({ orderId, receiptCode, customerName, token, onClose, onCreated }: {
  orderId: string
  receiptCode: string
  customerName: string
  token: string
  onClose: () => void
  onCreated: (shipment: TtnShipment) => void
}) {
  const { t } = useTranslation()
  const titleId = useId()
  const { ref, close, onCancel, onClick } = useDrawer({ openOnMount: true, onClose })
  const [recipientName, setRecipientName] = useState(customerName)
  const [description, setDescription] = useState(defaultParcelDescription)
  const [internalOrderNumber, setInternalOrderNumber] = useState(receiptCode)
  const [weight, setWeight] = useState('')
  const [declaredValue, setDeclaredValue] = useState('')
  const [loading, setLoading] = useState(true)
  const [previewReady, setPreviewReady] = useState(false)
  const [calculatedWeight, setCalculatedWeight] = useState<number | null>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    void getTtnPreview(orderId, token, controller.signal).then(result => {
      if (controller.signal.aborted) return
      if (!Number.isSafeInteger(result.declaredValueMinor)) throw new Error('Could not load the declared value.')
      setCalculatedWeight(result.weightGrams)
      setWeight(result.weightGrams == null ? '' : String(result.weightGrams))
      setDeclaredValue(String(result.declaredValueMinor / 100))
      setPreviewReady(true)
    }).catch(cause => {
      if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not calculate the order weight.')
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false)
    })
    return () => controller.abort()
  }, [orderId, token])

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (saving || !previewReady) return
    if (!parseTtnRecipientName(recipientName)) {
      setError(invalidTtnRecipientName)
      return
    }
    const weightGrams = Number(weight)
    if (!Number.isSafeInteger(weightGrams) || weightGrams <= 0) {
      setError('Enter a positive weight in whole grams.')
      return
    }
    if (!description.trim()) {
      setError('Enter a parcel description.')
      return
    }
    const declaredValueMinor = Math.round(Number(declaredValue) * 100)
    if (!Number.isSafeInteger(declaredValueMinor) || Number(declaredValue) < 1) {
      setError('Enter a declared value of at least 1 UAH.')
      return
    }

    setSaving(true)
    setError(null)
    try {
      const shipment = await createTtn(token, { orderId, description, internalOrderNumber, weightGrams, declaredValueMinor, recipientName })
      close(() => onCreated(shipment))
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not create TTN')
      setSaving(false)
    }
  }

  return <dialog ref={ref} className="order-drawer" aria-labelledby={titleId}
    onCancel={event => saving ? event.preventDefault() : onCancel(event)}
    onClick={event => { if (!saving) onClick(event) }}>
    <header className="order-drawer__header">
      <div className="order-drawer__identity">
        <span className="order-drawer__eyebrow">#{receiptCode}</span>
        <h2 id={titleId}>{t('Create TTN')}</h2>
      </div>
      <button type="button" className="btn btn--ghost" disabled={saving} onClick={() => close()}>{t('Close')}</button>
    </header>
    <div className="order-drawer__body">
      <form className="form order-drawer__card" onSubmit={event => void submit(event)}>
        <label className="field">
          <span>{t('Recipient surname and first name')}</span>
          <input required value={recipientName} disabled={saving} onChange={event => setRecipientName(event.target.value)} />
          <small>{t(invalidTtnRecipientName)}</small>
        </label>
        <label className="field">
          <span>{t('Parcel description')}</span>
          <textarea required value={description} disabled={saving}
            onChange={event => setDescription(event.target.value)} />
        </label>
        <label className="field">
          <span>{t('Internal order number (optional)')}</span>
          <input value={internalOrderNumber} disabled={saving} onChange={event => setInternalOrderNumber(event.target.value)} />
        </label>
        <label className="field">
          <span>{t('Weight, g')}</span>
          <input type="number" required min="1" step="1" value={weight} disabled={!previewReady || saving}
            onChange={event => setWeight(event.target.value)} />
          {loading ? <small role="status">{t('Calculating order weight…')}</small> : previewReady && <small>{calculatedWeight === null
            ? t('The order weight is unavailable. Enter the parcel weight manually.')
            : t('Total item weight is {{weight}} g. Adjust it if needed.', { weight: calculatedWeight })}</small>}
        </label>
        <label className="field">
          <span>{t('Declared value, UAH')}</span>
          <input type="number" required min="1" step="0.01" value={declaredValue} disabled={!previewReady || saving}
            onChange={event => setDeclaredValue(event.target.value)} />
        </label>
        {error && <p className="error" role="alert">{t(error)}</p>}
        <button type="submit" className="btn" disabled={!previewReady || saving}>{t(saving ? 'Creating TTN…' : 'Create TTN')}</button>
      </form>
    </div>
  </dialog>
}
