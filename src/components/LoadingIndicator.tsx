export function LoadingIndicator({ label, showLabel = false }: { label: string; showLabel?: boolean }) {
  return <div className="loading-indicator" role="status" aria-live="polite">
    <span className="loading-indicator__spinner" aria-hidden="true" />
    <span className={showLabel ? undefined : 'sr-only'}>{label}</span>
  </div>
}
