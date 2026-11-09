import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { supabaseRequest } from '../lib/supabase'

export function NovaPostModeToggle() {
  const { t } = useTranslation()
  const { store } = useStore(); const { token } = useAuth()
  const [testMode, setTestMode] = useState(true); const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null)
  useEffect(() => { if (!store || !token) return; void supabaseRequest<Array<{ nova_post_test_mode: boolean }>>(`/rest/v1/delivery_settings?store_id=eq.${encodeURIComponent(store.id)}&select=nova_post_test_mode`, { token }).then((rows) => { setTestMode(rows[0]?.nova_post_test_mode ?? true); setLoading(false) }).catch((cause) => { setError(cause instanceof Error ? cause.message : 'Could not load mode'); setLoading(false) }) }, [store, token])
  const change = async (value: boolean) => { if (!store || !token) return; setTestMode(value); setError(null); try { await supabaseRequest('/rest/v1/delivery_settings?on_conflict=store_id', { method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' }, body: JSON.stringify({ store_id: store.id, nova_post_test_mode: value }) }) } catch (cause) { setTestMode(!value); setError(cause instanceof Error ? cause.message : 'Could not save mode') } }
  return <section className="nova-mode">
    <div>
      <p className="eyebrow">{t('TTN environment')}</p>
      <h2>{t(testMode ? 'Test mode' : 'Live mode')}</h2>
      <p className="muted">{t(testMode ? 'Uses the Nova Poshta test API key.' : 'Uses the Nova Poshta production API key.')}</p>
    </div>
    <label className="mode-switch">
      <input type="checkbox" checked={testMode} disabled={loading} onChange={e => void change(e.target.checked)} />
      <span aria-hidden="true" />{t('Test mode')}
    </label>
    {error && <p className="error" role="alert">{error}</p>}
  </section>
}
