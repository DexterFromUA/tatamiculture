import { useEffect, useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { ThemeMode } from '../lib/storefrontTheme'

const options = [
  { mode: 'light', label: 'Light theme' },
  { mode: 'system', label: 'System theme' },
  { mode: 'dark', label: 'Dark theme' },
] as const

function ThemeIcon({ mode }: { mode: ThemeMode }) {
  return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    {mode === 'light' ? <><circle cx="12" cy="12" r="4" /><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5" /></>
      : mode === 'system' ? <><rect x="3" y="4" width="18" height="13" rx="2" /><path d="M12 17v4m-4 0h8" /></>
        : <path d="M20.8 13.2A9 9 0 0 1 10.8 3.2a9 9 0 1 0 10 10Z" />}
  </svg>
}

export function ThemeSwitch({ mode, theme, onChange }: { mode: ThemeMode; theme: 'light' | 'dark'; onChange: (mode: ThemeMode) => void }) {
  const { t } = useTranslation()
  const name = useId()
  const root = useRef<HTMLDivElement>(null)
  const trigger = useRef<HTMLButtonElement>(null)
  const pointerType = useRef('')
  const [open, setOpen] = useState(false)

  useEffect(() => {
    if (!open) return
    const dismiss = (event: PointerEvent) => {
      if (event.target instanceof Node && !root.current?.contains(event.target)) setOpen(false)
    }
    document.addEventListener('pointerdown', dismiss)
    return () => document.removeEventListener('pointerdown', dismiss)
  }, [open])

  return <div className="theme-switch-anchor"><div ref={root} className="theme-switch" role="group" aria-label={t('Choose theme')} data-mode={mode} data-open={open}
    onPointerDownCapture={event => { pointerType.current = event.pointerType }}
    onPointerEnter={event => { if (event.pointerType === 'mouse') setOpen(true) }}
    onPointerLeave={event => { if (event.pointerType === 'mouse' && !event.currentTarget.querySelector(':focus-visible')) setOpen(false) }}
    onBlur={event => {
      // Safari can blur the trigger with no next focus target before a radio's click/change.
      // Keep the options active for that tap; outside pointerdown still dismisses them.
      if (event.relatedTarget && !event.currentTarget.contains(event.relatedTarget)) setOpen(false)
    }}
    onKeyDown={event => {
      if (event.key === 'Escape') { event.preventDefault(); trigger.current?.focus(); setOpen(false) }
    }}>
    <button ref={trigger} type="button" className="theme-switch__trigger" aria-label={`${t('Choose theme')}: ${t(mode === 'system' ? 'System theme' : theme === 'dark' ? 'Dark theme' : 'Light theme')}`} aria-expanded={open} aria-controls={name} tabIndex={open ? -1 : 0} onClick={() => setOpen(true)}>
      <ThemeIcon mode={theme} />
    </button>
    <div id={name} className="theme-switch__options" role="radiogroup" aria-label={t('Choose theme')} inert={!open}>
      {options.map(option => <label className="theme-switch__option" key={option.mode} title={t(option.label)}>
        <input type="radio" name={name} value={option.mode} checked={mode === option.mode} onChange={event => {
          onChange(option.mode)
          if (pointerType.current !== 'mouse' && !event.currentTarget.matches(':focus-visible')) setOpen(false)
        }} onClick={event => {
          if (mode === option.mode && pointerType.current !== 'mouse' && !event.currentTarget.matches(':focus-visible')) setOpen(false)
        }} aria-label={t(option.label)} />
        <span className="theme-switch__icon"><ThemeIcon mode={option.mode} /></span>
      </label>)}
    </div>
  </div></div>
}
