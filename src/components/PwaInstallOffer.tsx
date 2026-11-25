import { useId, useState, useSyncExternalStore } from 'react'
import { useTranslation } from 'react-i18next'
import { dismissPwaInstallOffer, getPwaInstallState, promptPwaInstall, subscribeToPwaInstall } from '../lib/pwaInstall'
import { CenteredDialog } from './CenteredDialog'

export function PwaInstallOffer({ placement }: { placement: 'receipt' | 'footer' }) {
  const { t } = useTranslation()
  const { mode, dismissed } = useSyncExternalStore(subscribeToPwaInstall, getPwaInstallState)
  const [showInstructions, setShowInstructions] = useState(false)
  const titleId = useId()
  const receipt = placement === 'receipt'
  if (!mode || (receipt && dismissed)) return null

  const install = () => {
    if (mode === 'ios') setShowInstructions(true)
    else void promptPwaInstall().catch(() => {
      // The browser may withdraw an install prompt before it can be shown.
    })
  }

  return <>
    {receipt ? <section className="pwa-install-offer">
      <img src="/apple-touch-icon.png" width="48" height="48" alt="" />
      <div className="pwa-install-offer__copy">
        <h2>{t('Add Tatami to your home screen')}</h2>
        <p>{t('Track your orders and receive delivery updates.')}</p>
      </div>
      <div className="pwa-install-offer__actions">
        <button type="button" className="btn" aria-haspopup="dialog" onClick={install}>
          {t(mode === 'ios' ? 'How to add' : 'Install')}
        </button>
        <button type="button" className="text-btn" onClick={dismissPwaInstallOffer}>{t('Not now')}</button>
      </div>
    </section> : <button type="button" className="text-btn footer__install" aria-haspopup="dialog" onClick={install}>
      {t('Install app')}
    </button>}
    {mode === 'ios' && showInstructions && <CenteredDialog className="pwa-install-guide" aria-labelledby={titleId} onClose={() => setShowInstructions(false)}>
      <h2 id={titleId}>{t('Add Tatami to your home screen')}</h2>
      <ol>
        <li>
          {t('In Safari, tap Share.')}
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"
            strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M12 15V3m-4 4 4-4 4 4M8 10H6a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-7a2 2 0 0 0-2-2h-2" />
          </svg>
          <small>{t('If Share is hidden, open the page menu.')}</small>
        </li>
        <li>{t('Choose Add to Home Screen.')}</li>
        <li>{t('Turn on Open as Web App if offered, then tap Add.')}</li>
      </ol>
      <p>{t('If you opened this page inside another app, open it in Safari first.')}</p>
      <form method="dialog" className="confirmation-dialog__actions">
        <button type="submit" className="btn">{t('Close')}</button>
      </form>
    </CenteredDialog>}
  </>
}
