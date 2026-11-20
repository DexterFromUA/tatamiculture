import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import type { ThemeMode } from '../lib/storefrontTheme'

const options = [
  { mode: 'light', label: 'Light theme' },
  { mode: 'system', label: 'System theme' },
  { mode: 'dark', label: 'Dark theme' },
] as const

export function ThemeSwitch({ mode, onChange }: { mode: ThemeMode; onChange: (mode: ThemeMode) => void }) {
  const { t } = useTranslation()
  const name = useId()

  return <div className="theme-switch" role="group" aria-label={t('Choose theme')} data-mode={mode}>
    {options.map(option => <label className="theme-switch__option" key={option.mode} title={t(option.label)}>
      <input type="radio" name={name} value={option.mode} checked={mode === option.mode} onChange={() => onChange(option.mode)} aria-label={t(option.label)} />
      <span className="theme-switch__icon" aria-hidden="true">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
          {option.mode === 'light' ? <><circle cx="12" cy="12" r="4" /><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5" /></>
            : option.mode === 'system' ? <><rect x="3" y="4" width="18" height="13" rx="2" /><path d="M12 17v4m-4 0h8" /></>
              : <path d="M20.8 13.2A9 9 0 0 1 10.8 3.2a9 9 0 1 0 10 10Z" />}
        </svg>
      </span>
    </label>)}
  </div>
}
