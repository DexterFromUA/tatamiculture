import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'

const uk = {
  Shop: 'Магазин', Cart: 'Кошик', 'Sign in': 'Увійти', 'Sign out': 'Вийти', Account: 'Кабінет',
  'Opening store…': 'Відкриваємо магазин…', 'Store not found': 'Магазин не знайдено',
  'The storefront is unavailable right now.': 'Вітрина наразі недоступна.', 'Go to Tatami': 'До Tatami',
  'Mock payments only': 'Тестовий режим оплат', English: 'English', Ukrainian: 'Українська',
  'Cart is empty': 'Кошик порожній', 'Continue shopping': 'Продовжити покупки', Quantity: 'Кількість', Remove: 'Видалити', Total: 'Разом', Checkout: 'Оформити замовлення',
  'Product not found': 'Товар не знайдено', 'Back to shop': 'До магазину', Option: 'Варіант',
  'This option is a pre-order. Production starts after checkout.': 'Цей варіант доступний за передзамовленням. Виробництво розпочнеться після оформлення.',
  'Add to cart': 'Додати до кошика', 'View cart': 'Переглянути кошик', Sale: 'Знижка',
  'Added to cart': 'Додано до кошика', 'Previous image': 'Попереднє зображення', 'Next image': 'Наступне зображення', 'pre-order': 'передзамовлення',
  'Page not found': 'Сторінку не знайдено', 'Loading…': 'Завантаження…',
  'Secure checkout': 'Безпечне оформлення', 'Delivery details': 'Дані для доставки',
  'We will use these details only to prepare and send your order.': 'Ми використаємо ці дані лише для підготовки та відправлення замовлення.',
  Name: 'Ім’я', Email: 'Електронна пошта', Phone: 'Телефон', City: 'Місто', Address: 'Адреса', Note: 'Коментар',
  'Start typing your city': 'Почніть вводити місто', 'Choose branch': 'Оберіть відділення', 'Loading branches…': 'Завантаження відділень…',
  'Payment method': 'Спосіб оплати', 'Secure payment page': 'Захищена сторінка оплати', 'Payment on delivery': 'Оплата при отриманні',
  'Pay when receiving at Nova Poshta': 'Сплатіть під час отримання у Новій пошті', 'Your order': 'Ваше замовлення', items: 'товарів',
  Delivery: 'Доставка', 'Shipping cost is confirmed after dispatch.': 'Вартість доставки уточнюється після відправлення.',
  'Welcome back': 'З поверненням', 'Password': 'Пароль', 'New here?': 'Вперше тут?', 'Create an account': 'Створити акаунт',
  'Sign in to view your orders and manage your details.': 'Увійдіть, щоб переглядати замовлення та керувати своїми даними.',
  'Signing in…': 'Вхід…', 'Creating…': 'Створення…', 'Keep track of your training gear and every order in one place.': 'Стежте за спорядженням і всіма замовленнями в одному місці.',
  'Nothing to check out': 'Немає чого оформлювати', 'Choose a city and Nova Poshta branch': 'Оберіть місто й відділення Нової пошти',
  'Nova Poshta branch or parcel locker': 'Відділення або поштомат Нової пошти', 'Placing order…': 'Оформлення замовлення…', Pay: 'Сплатити',
  'Tatami account': 'Акаунт Tatami', 'Create account': 'Створити акаунт', 'Already have an account?': 'Вже маєте акаунт?',
  'Hi, {{name}}.': 'Вітаємо, {{name}}.', athlete: 'спортсмене', 'Your details and orders, kept together.': 'Ваші дані та замовлення в одному місці.',
  'Tatami customer': 'Клієнт Tatami', 'Your purchases': 'Ваші покупки', 'Order history': 'Історія замовлень',
  'Loading orders…': 'Завантаження замовлень…', 'No orders yet.': 'Замовлень ще немає.',
  'Looking up receipt…': 'Шукаємо замовлення…', 'Receipt not found': 'Замовлення не знайдено', Receipt: 'Замовлення', 'Thank you, {{name}}': 'Дякуємо, {{name}}',
  'Deliver to': 'Доставити до', 'TTN created — status will appear after dispatch.': 'ТТН створено — статус з’явиться після відправлення.', 'TTN will be added after dispatch.': 'ТТН буде додано після відправлення.', 'Track shipment': 'Відстежити відправлення',
  'CRM needs Supabase': 'CRM потребує Supabase', 'Manager access required': 'Потрібен доступ менеджера', 'Loading CRM…': 'Завантаження CRM…', management: 'керування',
  'Management sections': 'Розділи керування', 'Configure `.env.local` and apply the project migration first.': 'Налаштуйте `.env.local` і спочатку застосуйте міграцію проєкту.', 'Ask the store owner to add your account to this store.': 'Попросіть власника магазину додати ваш акаунт до команди.',
  Revenue: 'Виручка', 'Delivered revenue': 'Виручка за доставленими', 'Needs attention': 'Потребує уваги', 'pending orders': 'очікують обробки', 'failed payments': 'невдалі оплати', 'Open orders': 'Відкрити замовлення', 'Inventory alerts': 'Попередження про залишки', 'Manage catalogue': 'Керувати каталогом', Stock: 'Залишки',
  'Search name, email or receipt': 'Пошук за іменем, email або номером', 'All statuses': 'Усі статуси', 'No orders match these filters.': 'Немає замовлень за обраними фільтрами.', 'Order status': 'Статус замовлення', 'Cancel & restore stock': 'Скасувати й повернути залишок', Customer: 'Клієнт', 'Create TTN': 'Створити ТТН', 'Creating TTN…': 'Створення ТТН…', 'Update status': 'Оновити статус', 'Updating…': 'Оновлення…', 'Open storefront': 'Відкрити вітрину',
  'Orders from date': 'Замовлення від дати', 'Orders to date': 'Замовлення до дати', 'Online payment': 'Онлайн-оплата', 'Open customer card': 'Відкрити картку клієнта', 'Guest checkout has no customer account': 'Гостьове оформлення не має акаунта клієнта',
  Registered: 'Зареєстровані', 'New, 30 days': 'Нові за 30 днів', 'No orders yet': 'Ще без замовлень', 'Registered customers': 'Зареєстровані клієнти', joined: 'зареєструвався', orders: 'замовлень',
  'Loading catalogue…': 'Завантаження каталогу…', 'Add product': 'Додати товар', Published: 'Опубліковано', Hidden: 'Приховано', variants: 'варіантів', Edit: 'Редагувати', 'Edit product': 'Редагувати товар', 'New product': 'Новий товар', Close: 'Закрити', Description: 'Опис', Category: 'Категорія', Uncategorized: 'Без категорії', 'Upload images': 'Завантажити зображення', 'Published in storefront': 'Опубліковано у вітрині', 'Sizes and stock': 'Розміри та залишки', 'Add size': 'Додати розмір', Size: 'Розмір', Price: 'Ціна', 'Pre-order': 'Передзамовлення', 'Saving…': 'Збереження…', 'Save product': 'Зберегти товар', Cancel: 'Скасувати',
  SKU: 'Артикул', 'JPG, PNG or WebP · up to 5 MB per file': 'JPG, PNG або WebP · до 5 МБ на файл', Product: 'Товар', 'Select a product': 'Оберіть товар', 'Edit its sizes, prices, availability and main image.': 'Редагуйте розміри, ціни, доступність і головне зображення.',
  'Nova Poshta settings': 'Налаштування Нової пошти', 'TTN environment': 'Середовище ТТН', 'Sender name or company': 'Ім’я відправника або компанія', 'Sender phone': 'Телефон відправника', 'Dispatch city': 'Місто відправлення', 'Dispatch branch': 'Відділення відправлення', 'Parcel defaults': 'Параметри посилки', 'Weight, g': 'Вага, г', 'Length, cm': 'Довжина, см', 'Width, cm': 'Ширина, см', 'Height, cm': 'Висота, см', 'Declared value, UAH': 'Оціночна вартість, грн', 'Delivery payer': 'Платник доставки',
  PENDING: 'Очікує', PAID: 'Оплачено', IN_PROGRESS: 'В обробці', READY_FOR_PICKUP: 'Готово до видачі', DELIVERED: 'Доставлено', CANCELLED_BY_USER: 'Скасовано клієнтом', CANCELLED_BY_STORE: 'Скасовано магазином',
  CRM: 'CRM', Overview: 'Огляд', Orders: 'Замовлення', Customers: 'Клієнти', Catalogue: 'Каталог', Settings: 'Налаштування',
  Shipping: 'Доставка', Sender: 'Відправник', Recipient: 'Одержувач',
  'Save settings': 'Зберегти налаштування', Saved: 'Збережено', 'Test mode': 'Тестовий режим', 'Live mode': 'Бойовий режим',
}

const savedLanguage = typeof window === 'undefined' ? null : window.localStorage.getItem('tatami-language')

void i18n
  .use(initReactI18next)
  .init({
    resources: { en: { translation: {} }, uk: { translation: uk } },
    lng: savedLanguage === 'en' || savedLanguage === 'uk' ? savedLanguage : 'uk',
    fallbackLng: 'en',
    returnNull: false,
    interpolation: { escapeValue: false },
  })

i18n.on('languageChanged', (language) => {
  window.localStorage.setItem('tatami-language', language)
  document.documentElement.lang = language
})

export default i18n
