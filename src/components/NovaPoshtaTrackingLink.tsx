import type { MouseEvent, ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { useToast } from '../context/ToastContext'

function copyWhileFocused(number: string) {
  let copied = false
  const onCopy = (event: ClipboardEvent) => {
    if (!event.clipboardData) return
    event.clipboardData.setData('text/plain', number)
    event.preventDefault()
    copied = true
  }

  // Opening a tab can take focus before an asynchronous clipboard write finishes.
  document.addEventListener('copy', onCopy, { once: true })
  try {
    return document.execCommand('copy') && copied
  } catch {
    return false
  } finally {
    document.removeEventListener('copy', onCopy)
  }
}

export function NovaPoshtaTrackingLink({ ttn, className, children }: {
  ttn: string
  className?: string
  children: ReactNode
}) {
  const { t } = useTranslation()
  const { addToast } = useToast()

  const copyAndTrack = async (event: MouseEvent<HTMLAnchorElement>) => {
    const number = ttn.trim()
    if (copyWhileFocused(number)) {
      addToast(t('Tracking number copied'))
      return
    }

    event.preventDefault()
    const link = event.currentTarget.cloneNode() as HTMLAnchorElement
    try {
      await navigator.clipboard.writeText(number)
      addToast(t('Tracking number copied'))
    } catch {
      addToast(t('Could not copy the tracking number. You can copy it manually.'))
    }
    link.click()
  }

  return <a className={className} href="https://tracking.novaposhta.ua/#/uk/" target="_blank" rel="noreferrer"
    onClick={event => void copyAndTrack(event)}>{children}</a>
}
