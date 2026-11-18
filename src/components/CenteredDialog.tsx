import { useEffect, useRef, type ComponentProps } from 'react'

export function CenteredDialog({ className, onClose, busy, ...props }: Omit<ComponentProps<'dialog'>, 'onClose'> & {
  busy?: boolean
  onClose: (value: string) => void
}) {
  const ref = useRef<HTMLDialogElement>(null)

  useEffect(() => {
    const dialog = ref.current
    if (dialog && !dialog.open) dialog.showModal()
  }, [])

  return <dialog {...props} ref={ref}
    className={['confirmation-dialog', className].filter(Boolean).join(' ')}
    onCancel={event => { if (busy) event.preventDefault() }}
    onClose={event => onClose(event.currentTarget.returnValue)} />
}
