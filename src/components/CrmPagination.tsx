import { useTranslation } from 'react-i18next'

export function CrmPagination({ page, pages, loading, onChange }: {
  page: number; pages: number; loading?: boolean; onChange: (page: number) => void
}) {
  const { t } = useTranslation()
  return <nav className="crm-pagination" aria-label={t('Pagination')}>
    <button type="button" className="text-btn" disabled={loading || page <= 1} onClick={() => onChange(page - 1)}>{t('Previous')}</button>
    <span aria-current="page">{page} / {pages}</span>
    <button type="button" className="text-btn" disabled={loading || page >= pages} onClick={() => onChange(page + 1)}>{t('Next')}</button>
  </nav>
}
