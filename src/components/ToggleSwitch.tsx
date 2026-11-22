import type { ComponentPropsWithoutRef } from 'react'

type ToggleSwitchProps = Omit<ComponentPropsWithoutRef<'input'>, 'type' | 'role' | 'className' | 'children'>

export function ToggleSwitch(props: ToggleSwitchProps) {
  return <span className="toggle-switch">
    <input {...props} type="checkbox" role="switch" className="toggle-switch__input" />
    <span className="toggle-switch__track" aria-hidden="true" />
  </span>
}
