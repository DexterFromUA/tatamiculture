import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'

const uk = {
  'Your store, in one place.': 'Усе для керування магазином — в одному місці.', 'No low stock alerts.': 'Товарів із низьким залишком немає.', 'No customers match this search.': 'Клієнтів за цим запитом не знайдено.',
  'Order items': 'Товари в замовленні', 'Order details': 'Деталі замовлення', 'Payment status': 'Статус оплати', payment_PENDING: 'Очікує оплати', payment_PAID: 'Оплачено', payment_MOCK_PAID: 'Тестова оплата', payment_FAILED: 'Помилка оплати', payment_REFUNDED: 'Повернуто',
  'Show image {{number}}': 'Показати зображення {{number}}', '{{count}} available_one': 'В наявності: {{count}}', '{{count}} available_few': 'В наявності: {{count}}', '{{count}} available_many': 'В наявності: {{count}}', '{{count}} available_other': 'В наявності: {{count}}', 'Items in order: {{quantity}}': 'Товарів у замовленні: {{quantity}}', '{{quantity}} units': '{{quantity}} шт.', 'Details at checkout': 'Уточнюється під час оформлення', 'Payment is processed on the secure page of {{provider}}.': 'Оплата здійснюється на захищеній сторінці {{provider}}.',
  'Homepage banner': 'Банер головної сторінки', 'Empty fields use the default text.': 'Порожні поля використовують стандартний текст.', 'Banner image': 'Зображення банера', 'Remove banner image': 'Прибрати зображення банера', 'Banner eyebrow': 'Надпис над заголовком', 'Banner heading': 'Заголовок', 'Banner description': 'Опис', 'Save banner': 'Зберегти банер', 'Could not load banner': 'Не вдалося завантажити банер', 'Could not save banner': 'Не вдалося зберегти банер',
  'Made for movement': 'Створено для руху', 'Everyday movement': 'Рух щодня', 'Explore collection': 'До колекції', 'The collection': 'Колекція', 'All products': 'Усі товари', 'Find your essentials': 'Обирайте речі для свого ритму',
  'From {{price}}': 'Від {{price}}',
  'Latest 50 notifications': 'Останні 50 сповіщень',
  System: 'Система', Currency: 'Валюта', Created: 'Створено',
  'Search products': 'Пошук товарів за назвою або артикулом',
  'Order activity': 'Історія подій замовлення', 'No events yet': 'Подій поки немає', event_status: 'Статус замовлення', event_payment_status: 'Статус оплати', event_cost: 'Собівартість', event_return: 'Повернення',
  Notifications: 'Сповіщення', 'No notifications yet': 'Сповіщень поки немає', 'Mark as read': 'Позначити прочитаним', 'Action failed': 'Не вдалося виконати дію',
  'Forgot password': 'Забули пароль?', 'New password': 'Новий пароль', 'Recovery requires Supabase': 'Відновлення пароля доступне після підключення Supabase.', 'Recovery link invalid': 'Посилання відновлення недійсне. Запросіть нове.', 'Passwords do not match': 'Паролі не збігаються', 'Password updated': 'Пароль змінено. Увійдіть із новим паролем.', 'Recovery email sent': 'Якщо акаунт існує, лист із посиланням надіслано на вашу пошту.', 'Confirm password': 'Підтвердіть пароль', 'Save password': 'Зберегти пароль', 'Send recovery email': 'Надіслати посилання',
  'Order operations': 'Події та фінанси', 'Order cost': 'Собівартість замовлення', Save: 'Зберегти', Returns: 'Повернення', 'Return accounting only': 'Облік підтвердженого повернення. Не виконує банківське відшкодування й не змінює залишки.', 'Return amount': 'Сума повернення', Reason: 'Причина', 'Record return': 'Записати повернення', 'Invalid amount': 'Вкажіть коректну суму',
  'Financial analytics': 'Фінансова аналітика', 'Repeat customers': 'Повторні покупці', 'Net delivered revenue': 'Виручка за доставленими після повернень', 'Gross margin': 'Валова маржа', 'Cost coverage': 'Замовлення з відомою собівартістю', 'Margin explanation': 'Маржа лише за доставленими замовленнями з введеною собівартістю, мінус повернення. Без комісій, податків та операційних витрат. Повторні покупці — за нескансованими замовленнями.',
  'Export CSV': 'Експорт CSV', Previous: 'Назад', Next: 'Далі', 'Search customers': 'Пошук клієнтів за іменем або телефоном',
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
  Products: 'Товари', 'Stock units': 'Одиниць на складі', 'Low stock': 'Мало в наявності', 'Out of stock': 'Немає в наявності', 'out of stock': 'без залишку', 'in stock': 'шт. в наявності', 'All categories': 'Усі категорії', 'Stock filter': 'Фільтр залишків', 'All stock': 'Усі залишки', 'No SKU': 'Без артикулу', 'No products match these filters.': 'За цими фільтрами товарів немає.', 'Price, UAH': 'Ціна, грн', 'Stock, units': 'Залишок, шт.',
  'Manage categories': 'Керувати категоріями', 'Create category': 'Створити категорію', 'New category': 'Нова категорія', 'Rename category': 'Перейменувати категорію', Rename: 'Перейменувати', Delete: 'Видалити', 'Enter a category name.': 'Введіть назву категорії.', 'This category already exists.': 'Така категорія вже існує.', 'Could not create category.': 'Не вдалося створити категорію.', 'Could not save category.': 'Не вдалося зберегти категорію.', 'Could not delete category.': 'Не вдалося видалити категорію.', 'Move products to another category first.': 'Спочатку перемістіть товари до іншої категорії.', 'Delete category "{{name}}"?': 'Видалити категорію «{{name}}»?',
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
    resources: { en: { translation: {
      payment_PENDING: 'Awaiting payment', payment_PAID: 'Paid', payment_MOCK_PAID: 'Test payment', payment_FAILED: 'Payment failed', payment_REFUNDED: 'Refunded',
      event_status: 'Order status', event_payment_status: 'Payment status', event_cost: 'Cost', event_return: 'Return',
      PENDING: 'Pending', PAID: 'Paid', IN_PROGRESS: 'In progress', READY_FOR_PICKUP: 'Ready for pickup', DELIVERED: 'Delivered', CANCELLED_BY_USER: 'Cancelled by customer', CANCELLED_BY_STORE: 'Cancelled by store',
      'Return accounting only': 'Records a confirmed return only. Does not issue a bank refund or restock inventory.',
      'Margin explanation': 'Delivered orders with a known cost only, less recorded returns. Excludes fees, taxes and operating costs. Repeat customers are based on non-cancelled orders.',
      'Recovery email sent': 'If the account exists, a recovery link has been sent.', 'Recovery link invalid': 'The recovery link is invalid. Request a new one.',
    } }, uk: { translation: uk } },
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
