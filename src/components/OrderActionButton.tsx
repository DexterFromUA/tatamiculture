import { useId, type ComponentPropsWithoutRef } from 'react'

export function OrderActionButton({ disabledReason, ...props }: Omit<ComponentPropsWithoutRef<'button'>, 'disabled'> & {
  disabledReason?: string
}) {
  const hintId = useId()
  if (!disabledReason) return <button {...props} />

  return <span className="order-action">
    <button {...props} disabled aria-describedby={hintId} />
    <small id={hintId} className="order-action__hint">{disabledReason}</small>
  </span>
}
