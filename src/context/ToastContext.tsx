import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

type Toast = { id: number; message: string }

type ToastContextValue = {
  toasts: Toast[]
  addToast: (message: string) => void
}

const ToastContext = createContext<ToastContextValue | null>(null)

function ToastCard({ toast, dismiss }: { toast: Toast; dismiss: (id: number) => void }) {
  const { t } = useTranslation()

  useEffect(() => {
    const timer = window.setTimeout(() => dismiss(toast.id), 2800)
    return () => window.clearTimeout(timer)
  }, [toast.id, dismiss])

  return <div className="toast">
    <p className="toast__message">{toast.message}</p>
    <button type="button" className="toast__close" aria-label={t('Dismiss notification')} onClick={() => dismiss(toast.id)}>
      <span aria-hidden="true">×</span>
    </button>
  </div>
}

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])
  const nextId = useRef(0)

  const dismiss = useCallback((id: number) => {
    setToasts(current => current.filter(toast => toast.id !== id))
  }, [])

  const addToast = useCallback((message: string) => {
    const id = ++nextId.current
    setToasts(current => [...current, { id, message }])
  }, [])

  const value = useMemo(() => ({ toasts, addToast }), [toasts, addToast])

  return (
    <ToastContext.Provider value={value}>
      {children}
      <div className="toast-stack" aria-live="polite">
        {toasts.map(toast => <ToastCard key={toast.id} toast={toast} dismiss={dismiss} />)}
      </div>
    </ToastContext.Provider>
  )
}

export function useToast() {
  const context = useContext(ToastContext)
  if (!context) throw new Error('useToast must be used inside ToastProvider')
  return context
}
