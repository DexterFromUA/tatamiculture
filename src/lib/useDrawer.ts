import { useCallback, useEffect, useRef, type MouseEvent, type SyntheticEvent } from 'react'

export function useDrawer({ openOnMount = false, onClose }: {
  openOnMount?: boolean
  onClose?: () => void
} = {}) {
  const ref = useRef<HTMLDialogElement>(null)
  const openingFrame = useRef<number | null>(null)

  const open = useCallback(() => {
    const panel = ref.current
    if (!panel || panel.open) return
    panel.showModal()
    // Paint the starting position without forcing synchronous layout.
    openingFrame.current = requestAnimationFrame(() => {
      openingFrame.current = requestAnimationFrame(() => {
        openingFrame.current = null
        if (panel.open) panel.setAttribute('data-visible', '')
      })
    })
  }, [])

  useEffect(() => {
    const panel = ref.current
    if (openOnMount) open()
    return () => {
      if (openingFrame.current !== null) cancelAnimationFrame(openingFrame.current)
      openingFrame.current = null
      panel?.removeAttribute('data-visible')
      panel?.close()
    }
  }, [open, openOnMount])

  const close = (afterClose?: () => void) => {
    const panel = ref.current
    if (!panel?.open) return
    if (openingFrame.current !== null) cancelAnimationFrame(openingFrame.current)
    openingFrame.current = null
    panel.removeAttribute('data-visible')

    const finish = () => {
      if (!panel.open || panel.hasAttribute('data-visible')) return
      panel.close()
      onClose?.()
      afterClose?.()
    }

    const transitions = panel.getAnimations()
    if (transitions.length === 0) finish()
    else void Promise.allSettled(transitions.map(transition => transition.finished)).then(finish)
  }

  const onCancel = (event: SyntheticEvent<HTMLDialogElement>) => {
    event.preventDefault()
    close()
  }

  const onClick = (event: MouseEvent<HTMLDialogElement>) => {
    if (event.target !== event.currentTarget) return
    const { left, right, top, bottom } = event.currentTarget.getBoundingClientRect()
    if (event.clientX < left || event.clientX >= right || event.clientY < top || event.clientY >= bottom) close()
  }

  return { ref, open, close, onCancel, onClick }
}
