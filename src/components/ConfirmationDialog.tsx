import { useEffect, useId, useRef } from 'react'
import { useTranslation } from 'react-i18next'

export type ConfirmationDialogContent = {
  title: string
  message: string
  details?: string[]
  confirmLabel?: string
  confirmDisabled?: boolean
}

export function ConfirmationDialog({ title, message, details, confirmLabel, confirmDisabled, onClose }: ConfirmationDialogContent & {
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
      className="confirmation-dialog"
      role="alertdialog"
      aria-labelledby={titleId}
      aria-describedby={messageId}
      onClose={event => onClose(event.currentTarget.returnValue === 'confirm')}
    >
      <h2 id={titleId}>{title}</h2>
      <p id={messageId}>{message}</p>
      {details?.length ? (
        <ul className="confirmation-dialog__details">
          {details.map(detail => <li key={detail}>{detail}</li>)}
        </ul>
      ) : null}
      <form method="dialog" className="confirmation-dialog__actions">
        <button type="submit" value="cancel" className="btn btn--ghost" autoFocus>{t('Cancel')}</button>
        <button type="submit" value="confirm" className="btn" disabled={confirmDisabled}>{confirmLabel ?? t('Confirm')}</button>
      </form>
    </dialog>
  )
}
