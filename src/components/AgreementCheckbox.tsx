import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { agreementPath } from '../content/agreement'

type AgreementCheckboxProps = {
  checked: boolean
  onChange: (accepted: boolean) => void
  disabled: boolean
  form?: string
}

export function AgreementCheckbox({ checked, onChange, disabled, form }: AgreementCheckboxProps) {
  const { t } = useTranslation()
  return <label className="agreement-checkbox">
    <input type="checkbox" name="accept-agreement" form={form} required checked={checked} disabled={disabled}
      onChange={event => onChange(event.target.checked)} />
    <span>{t('I have read and accept the')} <Link to={agreementPath} target="_blank" rel="noopener noreferrer">{t('user agreement')}</Link>{t(', including the personal data processing terms.')}</span>
  </label>
}
