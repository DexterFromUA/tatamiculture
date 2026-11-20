import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useStore } from '../context/StoreContext'
import { agreement, agreementVersion, seller } from '../content/agreement'
import { agreementServices } from '../content/agreementServices'
import { contactsChanged, getStorefrontContacts } from '../lib/storefrontContacts'

export function AgreementPage() {
  const { i18n, t } = useTranslation()
  const { store } = useStore()
  const language = i18n.resolvedLanguage === 'en' ? 'en' : 'uk'
  const content = agreement[language]
  const [instagram, setInstagram] = useState('')
  const storeId = store?.id

  useEffect(() => {
    if (!storeId) return
    let active = true
    const load = () => {
      void getStorefrontContacts(storeId).then(contacts => {
        if (active) setInstagram(/^https:\/\/(www\.)?instagram\.com\/[A-Za-z0-9._]+\/?$/i.test(contacts.instagram_url) ? contacts.instagram_url : '')
      }).catch(() => { /* Email remains available when the optional social link cannot load. */ })
    }
    load()
    window.addEventListener(contactsChanged, load)
    return () => { active = false; window.removeEventListener(contactsChanged, load) }
  }, [storeId])

  return <article className="agreement-page" lang={language}>
    <header className="agreement-page__header">
      <p className="eyebrow">tatami.culture / {t('Legal information')}</p>
      <h1>{content.title}</h1>
      <p className="muted">{content.subtitle}</p>
      <p className="agreement-page__version">{t('Version')} <time dateTime={agreementVersion}>{agreementVersion}</time></p>
    </header>
    <nav className="agreement-page__contents" aria-label={t('Agreement contents')}>
      {content.sections.map(section => <a href={`#${section.id}`} key={section.id}>{section.title}</a>)}
      <a href="#seller">{t('Seller details and contacts')}</a>
    </nav>
    {content.sections.map(section => <section id={section.id} key={section.id} className="agreement-page__section">
      <h2>{section.title}</h2>
      {section.paragraphs.map(paragraph => <p key={paragraph}>{paragraph}</p>)}
      {section.id === 'services' && <div className="agreement-services">
        {agreementServices.map(service => <div className="agreement-services__item" key={service.name}>
          <h3><a href={service.url} target="_blank" rel="noopener noreferrer">{service.name} ↗</a></h3>
          <p>{service.purpose[language]}</p><p className="muted">{service.data[language]}</p>
        </div>)}
      </div>}
    </section>)}
    <section id="seller" className="agreement-page__section">
      <h2>{t('Seller details and contacts')}</h2>
      <dl className="agreement-seller">
        <div><dt>{t('Seller')}</dt><dd>{seller.name}</dd></div>
        <div><dt>{t('Tax registration number')}</dt><dd>{seller.taxId}</dd></div>
        <div><dt>{t('Registered address')}</dt><dd>{seller.address}</dd></div>
        <div><dt>Email</dt><dd><a href={`mailto:${seller.email}`}>{seller.email}</a></dd></div>
        {instagram && <div><dt>Instagram</dt><dd><a href={instagram} target="_blank" rel="noopener noreferrer">@{instagram.split('/').filter(Boolean).pop()} ↗</a></dd></div>}
      </dl>
      <p>{t('Contact the seller before sending a return to confirm the delivery address.')}</p>
      <p className="muted">{t('Legal framework')}: <a href="https://zakon.rada.gov.ua/laws/show/675-19#Text" target="_blank" rel="noopener noreferrer">{t('Electronic commerce')}</a>, <a href="https://zakon.rada.gov.ua/laws/show/1023-12#Text" target="_blank" rel="noopener noreferrer">{t('Consumer protection')}</a>, <a href="https://zakon.rada.gov.ua/laws/show/2297-17#Text" target="_blank" rel="noopener noreferrer">{t('Personal data protection')}</a>.</p>
    </section>
  </article>
}
