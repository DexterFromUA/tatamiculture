type Language = 'uk' | 'en'
type Localized = Record<Language, string>

const statusTitles: Readonly<Record<string, Localized>> = {
  PENDING: { uk: 'Замовлення очікує підтвердження', en: 'Order awaiting confirmation' },
  PAID: { uk: 'Замовлення оплачено', en: 'Order paid' },
  IN_PROGRESS: { uk: 'Замовлення в обробці', en: 'Order being processed' },
  WAITING_FOR_STOCK: { uk: 'Замовлення очікує надходження товару', en: 'Order awaiting stock' },
  PREPARING_SHIPMENT: { uk: 'Замовлення готується до відправлення', en: 'Order being prepared for shipment' },
  IN_TRANSIT: { uk: 'Замовлення в дорозі', en: 'Order in transit' },
  READY_FOR_PICKUP: { uk: 'Замовлення готове до видачі', en: 'Order ready for pickup' },
  DELIVERED: { uk: 'Замовлення доставлено', en: 'Order delivered' },
  COMPLETED: { uk: 'Замовлення завершено', en: 'Order completed' },
  CANCELLED_BY_USER: { uk: 'Замовлення скасовано', en: 'Order cancelled' },
  CANCELLED_BY_STORE: { uk: 'Замовлення скасовано', en: 'Order cancelled' },
}
const updated: Localized = { uk: 'Замовлення оновлено', en: 'Order updated' }
const viewReceipt: Localized = { uk: 'Відкрийте чек замовлення, щоб переглянути деталі.', en: 'Open the order receipt for details.' }
const statusBodies: Readonly<Record<string, Localized>> = {
  PENDING: { uk: 'Ми ще не підтвердили замовлення.', en: 'Your order has not been confirmed yet.' },
  PAID: { uk: 'Ми отримали оплату за замовлення.', en: 'We received your order payment.' },
  IN_PROGRESS: { uk: 'Ми прийняли замовлення й почали його обробляти.', en: 'We received your order and are processing it.' },
  WAITING_FOR_STOCK: { uk: 'Підготуємо відправлення, щойно товар надійде.', en: 'We’ll prepare your shipment as soon as the item arrives.' },
  PREPARING_SHIPMENT: { uk: 'Готуємо посилку до передачі перевізнику.', en: 'We’re getting your parcel ready for the carrier.' },
  IN_TRANSIT: { uk: 'Перевізник везе посилку до місця отримання.', en: 'The carrier is taking your parcel to its destination.' },
  READY_FOR_PICKUP: { uk: 'Посилку вже можна забрати.', en: 'You can now pick up your parcel.' },
  DELIVERED: { uk: 'Посилка прибула до місця отримання.', en: 'Your parcel has arrived at its destination.' },
  COMPLETED: { uk: 'Замовлення виконано.', en: 'Your order has been fulfilled.' },
  CANCELLED_BY_USER: { uk: 'Ви скасували замовлення.', en: 'You cancelled your order.' },
  CANCELLED_BY_STORE: { uk: 'Магазин скасував замовлення.', en: 'The shop cancelled your order.' },
}

const shipmentCopy: Readonly<Record<string, { title: Localized; body: Localized }>> = {
  in_transit: { title: statusTitles.IN_TRANSIT, body: statusBodies.IN_TRANSIT },
  received: {
    title: { uk: 'Посилку отримано', en: 'Parcel received' },
    body: { uk: 'Нова пошта підтвердила видачу посилки.', en: 'Nova Poshta confirmed that the parcel was handed over.' },
  },
  refused: {
    title: { uk: 'Від отримання посилки відмовилися', en: 'Parcel delivery declined' },
    body: { uk: 'Нова пошта зафіксувала відмову від отримання.', en: 'Nova Poshta recorded that the delivery was declined.' },
  },
  rerouted: {
    title: { uk: 'Адресу доставки змінено', en: 'Delivery address changed' },
    body: { uk: 'Нова пошта перенаправила посилку. Актуальне місце отримання є у відстеженні.', en: 'Nova Poshta rerouted your parcel. Check tracking for the updated pickup location.' },
  },
  storage_ended: {
    title: { uk: 'Зберігання посилки завершено', en: 'Parcel storage ended' },
    body: { uk: 'Нова пошта припинила зберігання. Перевірте подальший маршрут у відстеженні.', en: 'Nova Poshta has ended storage. Check tracking for the parcel’s next destination.' },
  },
  missed: {
    title: { uk: 'Посилку не вдалося вручити', en: 'Delivery attempt unsuccessful' },
    body: { uk: 'Нова пошта повідомила про невдалу спробу доставки.', en: 'Nova Poshta reported an unsuccessful delivery attempt.' },
  },
  rescheduled: {
    title: { uk: 'Доставку перенесено', en: 'Delivery rescheduled' },
    body: { uk: 'Нова пошта оновила дату доставки. Новий термін є у відстеженні.', en: 'Nova Poshta changed the delivery date. Check tracking for the new date.' },
  },
}

function pickupCopy(kind: string, language: Language) {
  const [, code, paidStorageDate] = kind.split(':')
  if (code === '8') {
    return language === 'uk'
      ? { title: 'Посилка вже в поштоматі', body: 'Можете забрати її. Звичайний термін зберігання в поштоматі — 5 днів.' }
      : { title: 'Your parcel is in the locker', body: 'It’s ready for pickup. Parcels usually stay in lockers for 5 days.' }
  }
  const date = /^20\d{2}-\d{2}-\d{2}$/.test(paidStorageDate) ? new Date(`${paidStorageDate}T00:00:00Z`) : null
  const day = date && Number.isFinite(date.getTime()) ? new Intl.DateTimeFormat(language === 'uk' ? 'uk-UA' : 'en-GB', {
    day: 'numeric', month: 'long', timeZone: 'UTC',
  }).format(date) : null
  return language === 'uk'
    ? { title: 'Посилка вже у відділенні', body: day ? `Можете забрати її. Платне зберігання з ${day}.` : 'Можете забрати її. Зазвичай безплатне зберігання триває 5 днів після прибуття.' }
    : { title: 'Your parcel is at the branch', body: day ? `It’s ready for pickup. Storage fees apply from ${day}.` : 'It’s ready for pickup. Free storage usually lasts 5 days after arrival.' }
}

function discountCopy(kind: string, language: Language) {
  const [, , event, rawPercent, mode, first, last] = kind.split(':')
  const locale = language === 'uk' ? 'uk-UA' : 'en-GB'
  const percent = new Intl.NumberFormat(locale, { style: 'percent', maximumFractionDigits: 2 })
    .format(Number(rawPercent) / 100)
  const date = new Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeZone: 'UTC' })
  const title = language === 'uk'
    ? (event === 'assigned' ? `Вам нараховано персональну знижку ${percent}` : `Персональну знижку оновлено до ${percent}`)
    : (event === 'assigned' ? `You have a personal discount of ${percent}` : `Your personal discount is now ${percent}`)
  let body = language === 'uk' ? 'Знижка застосовується автоматично під час оформлення.' : 'The discount applies automatically at checkout.'

  if (mode === 'orders') {
    body = language === 'uk' ? `Кількість замовлень зі знижкою: ${first}.` : `Valid for ${first} ${first === '1' ? 'order' : 'orders'}.`
  } else if (mode === 'period') {
    const starts = date.format(new Date(`${first}T00:00:00Z`))
    const ends = date.format(new Date(`${last}T00:00:00Z`))
    body = language === 'uk' ? `Діє з ${starts} до ${ends} включно.` : `Valid from ${starts} through ${ends}.`
  }
  return { title, body }
}

export function notificationCopy(kind: string, language: Language): { title: string; body: string; legacyBody?: string } {
  if (kind.startsWith('manual:')) {
    const body = kind.slice('manual:'.length)
    return { title: language === 'uk' ? 'Повідомлення' : 'Notification', body, legacyBody: body }
  }
  if (kind.startsWith('discount:')) return discountCopy(kind, language)
  if (kind.startsWith('pickup:')) return pickupCopy(kind, language)
  if (kind.startsWith('shipment:')) {
    const [, status] = kind.split(':')
    if (Object.hasOwn(shipmentCopy, status)) {
      return { title: shipmentCopy[status].title[language], body: shipmentCopy[status].body[language] }
    }
  }
  if (kind === 'status:COMPLETED:received') {
    return { title: statusTitles.COMPLETED[language], body: shipmentCopy.received.body[language] }
  }
  if (kind.startsWith('payment_retry:') || kind === 'payment_status:FAILED') {
    const retry = kind.startsWith('payment_retry:checkout:')
    const reserved = kind.startsWith('payment_retry:reserved:')
    return language === 'uk'
      ? { title: 'Оплату не завершено', body: retry ? 'Відкрийте оформлення, щоб перевірити кошик і спробувати ще раз.' : reserved ? 'Замовлення збережено. Повторіть оплату в кабінеті.' : 'Платіж не підтверджено. Перевірте стан замовлення в чеку.' }
      : { title: 'Payment was not completed', body: retry ? 'Open checkout to review your cart and try again.' : reserved ? 'Your order is saved. Retry payment from your account.' : 'The payment was not confirmed. Check your order receipt.' }
  }
  if (kind === 'payment_status:PAID' || kind === 'payment_status:MOCK_PAID') {
    return language === 'uk'
      ? { title: 'Оплату підтверджено', body: 'Ми отримали оплату за замовлення.' }
      : { title: 'Payment confirmed', body: 'We received your order payment.' }
  }
  if (kind === 'payment_status:PENDING') {
    return language === 'uk'
      ? { title: 'Замовлення очікує оплати', body: 'Платіж ще не підтверджено.' }
      : { title: 'Order awaiting payment', body: 'The payment has not been confirmed yet.' }
  }
  if (kind === 'return' || kind === 'payment_status:REFUNDED') {
    return language === 'uk'
      ? { title: 'Кошти повернено', body: 'Повернення підтверджено. Строк зарахування залежить від способу оплати.' }
      : { title: 'Your refund is confirmed', body: 'Your refund was issued. The time it takes to appear depends on the payment method.' }
  }
  if (kind === 'status:IN_PROGRESS:cod') {
    return { title: statusTitles.IN_PROGRESS[language], body: language === 'uk' ? 'Ми прийняли замовлення. Оплата при отриманні.' : 'We received your order. Payment is due on delivery.' }
  }
  if (kind.startsWith('ttn_ready:')) {
    return language === 'uk'
      ? { title: 'Ваша ТТН готова', body: 'Відкрийте чек замовлення, щоб переглянути номер відстеження.' }
      : { title: 'Your waybill is ready', body: 'Open the order receipt to view your tracking number.' }
  }
  if (kind === 'restock') {
    return language === 'uk'
      ? { title: 'Товар знову в наявності', body: 'Відкрийте товар, на який ви чекали.' }
      : { title: 'Item back in stock', body: 'Open the item you were waiting for.' }
  }
  if (kind === 'payment_status') {
    return { title: language === 'uk' ? 'Статус оплати оновлено' : 'Payment status updated', body: viewReceipt[language] }
  }
  const status = kind.startsWith('status:') ? kind.slice('status:'.length) : ''
  const title = Object.hasOwn(statusTitles, status) ? statusTitles[status][language] : updated[language]
  const body = Object.hasOwn(statusBodies, status) ? statusBodies[status][language] : viewReceipt[language]
  return { title, body }
}
