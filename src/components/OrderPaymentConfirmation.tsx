import { useEffect, useId, useRef } from 'react'
import { useTranslation } from 'react-i18next'

export function OrderPaymentConfirmation({ message, onClose }: {
  message: string
  onClose: (confirmed: boolean) => void
}) {
  const { t } = useTranslation()
  const titleId = useId()
  const messageId = useId()
  const ref = useRef<HTMLDialogElement>(null)

  useEffect(() => {
    const dialog = ref.current
    if (dialog && !dialog.open) dialog.showModal()
  }, [])

  return (
    <dialog
      ref={ref}
      className="order-payment-confirmation"
      role="alertdialog"
      aria-labelledby={titleId}
      aria-describedby={messageId}
      onClose={event => onClose(event.currentTarget.returnValue === 'confirm')}
    >
      <h2 id={titleId}>{t('Payment recorded')}</h2>
      <p id={messageId}>{message}</p>
      <form method="dialog" className="order-payment-confirmation__actions">
        <button type="submit" value="cancel" className="btn btn--ghost" autoFocus>{t('Cancel')}</button>
        <button type="submit" value="confirm" className="btn">{t('Confirm')}</button>
      </form>
    </dialog>
  )
}
