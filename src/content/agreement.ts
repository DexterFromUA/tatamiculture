export const agreementVersion = '2026-11-20'
export const agreementPath = '/agreement'
export const seller = {
  name: 'ФОП Яковішина Дарʼя Андріївна',
  taxId: '3620003508',
  address: 'Україна, м. Кривий Ріг, Дніпровське шосе, буд. 36, кв. 117',
  email: 'tatami.culture@gmail.com',
}

type Section = { id: string; title: string; paragraphs: string[] }

export const agreement = {
  uk: {
    title: 'Угода користувача',
    subtitle: 'Умови користування магазином, купівлі товарів та обробки персональних даних',
    sections: [
      { id: 'general', title: '1. Загальні положення та продавець', paragraphs: [
        'Ця Угода визначає умови користування інтернет-магазином tatami.culture, створення облікового запису, замовлення товарів і обробки персональних даних. Продавець та володілець персональних даних — ФОП Яковішина Дарʼя Андріївна, реєстраційний номер облікової картки платника податків 3620003508. Адреса реєстрації: Україна, м. Кривий Ріг, Дніпровське шосе, буд. 36, кв. 117. Звернення приймаються на tatami.culture@gmail.com; додатковий канал зв’язку — Instagram магазину, посилання на який наведене нижче.',
        'Відносини сторін регулюються законодавством України, зокрема нормами про електронну комерцію, захист прав споживачів і персональних даних. Обов’язкові права споживача мають перевагу над положеннями цієї Угоди. Реєстрація сама по собі не створює обов’язку купити товар.',
      ] },
      { id: 'account', title: '2. Реєстрація та безпека облікового запису', paragraphs: [
        'Для реєстрації користувач надає достовірне ім’я та номер телефону, самостійно позначає згоду з цією Угодою та підтверджує контроль над номером одноразовим SMS-кодом. Передавати коди іншим особам або створювати акаунт із чужими даними без належних повноважень заборонено.',
        'Ми фіксуємо редакцію Угоди, з якою погодився користувач, та час її прийняття. Автопідстановка SMS-коду залежить від браузера й дозволів пристрою та не надає магазину доступу до інших повідомлень. Якщо номер втрачено або є підозра на сторонній доступ, зверніться до продавця.',
        'Користувач повинен мати необхідну цивільну дієздатність для своїх дій; у випадках, визначених законом, неповнолітні діють за участю або згодою законного представника.',
      ] },
      { id: 'orders', title: '3. Товари та оформлення замовлення', paragraphs: [
        'Характеристики, розміри, ціна та доступність товару наведені в каталозі. Користувач перевіряє склад замовлення, контактні дані, адресу або відділення доставки та спосіб оплати перед підтвердженням. Фотографії можуть відрізнятися за відтінком через налаштування екрана; це не скасовує вимог щодо відповідності товару опису.',
        'Договір щодо конкретної покупки укладається після підтвердження замовлення продавцем, у тому числі автоматичного підтвердження прийнятого оплаченого замовлення. Підтвердження містить склад і вартість покупки. У разі помилки в ціні або відсутності товару продавець зв’язується з покупцем: зміна складу, суми чи строків потребує погодження. Якщо виконати замовлення неможливо, отримані кошти підлягають поверненню за законом.',
        'Для передзамовлень або товарів під замовлення строк відправлення погоджується окремо до оплати. Позначка про можливість замовлення за відсутності залишку не означає негайну наявність товару.',
      ] },
      { id: 'payment', title: '4. Ціна, оплата та доставка', paragraphs: [
        'До підтвердження покупки відображаються ціна товарів, доступні знижки та сума замовлення. Плата за доставку й комісія післяплати, якщо вони сплачуються окремо перевізнику чи фінансовому сервісу, визначаються обраним тарифом і повідомляються до завершення оформлення. Розрахунки з продавцем здійснюються у гривні; довідкові валютні перерахунки не змінюють погоджену суму.',
        'Доступні способи оплати відображаються під час оформлення. Для онлайн-оплати користувач переходить до платіжного провайдера. Реквізити картки та CVV вводяться на його захищеній стороні й не зберігаються магазином. Результат оплати визначається підтвердженням провайдера, а не самим переходом назад на сайт. Продавець надає передбачений законом розрахунковий документ; сторінка замовлення не замінює його, коли закон вимагає фіскального документа.',
        'Доставка здійснюється обраним під час оформлення способом, зокрема Новою поштою. Строки відправлення та орієнтовний час перевезення повідомляються покупцю. Покупець перевіряє упаковку і товар під час отримання та, за наявності пошкоджень, за можливості фіксує їх із перевізником. Відсутність такої фіксації сама по собі не позбавляє законних прав споживача.',
      ] },
      { id: 'returns', title: '5. Скасування, обмін, повернення та недоліки', paragraphs: [
        'Для скасування, обміну, повернення товару або звернення щодо його недоліків напишіть на tatami.culture@gmail.com із номером замовлення та описом ситуації. Продавець надасть адресу й інструкції для повернення; не надсилайте товар на випадкове відділення.',
        'Обмін товару належної якості можливий у передбачений законом строк, за загальним правилом — протягом 14 днів без урахування дня купівлі, якщо товар не використовувався та збережено його вигляд, властивості, пломби й ярлики та підтвердження покупки. Для дистанційних договорів діє також передбачене законом право на відмову; його строки, початок перебігу й винятки визначає закон.',
        'Законодавчі обмеження для окремих категорій товарів належної якості застосовуються лише в установлених законом випадках. Сам факт належності речі до спортивного одягу не виключає права на повернення. За недоліків товару зберігаються права на ремонт, заміну, зменшення ціни або повернення коштів у випадках, передбачених законом. Знижка не скасовує цих прав.',
        'Повернення коштів, строки й розподіл витрат на пересилання визначаються законом та підставою повернення. Продавець повідомляє порядок до відправлення товару назад і не встановлює довільних утримань, які обмежують обов’язкові права покупця.',
      ] },
      { id: 'use', title: '6. Правила користування та права на матеріали', paragraphs: [
        'Сайт, його оформлення, тексти, фотографії та позначення охороняються правами відповідних правовласників. Користувач отримує невиключний дозвіл користуватися сайтом для перегляду, особистих покупок і керування власними замовленнями. Це не передає прав на торговельні марки або комерційне відтворення матеріалів.',
        'Заборонені несанкціонований доступ, втручання в оплату або облік залишків, шахрайські замовлення, поширення шкідливого коду та порушення прав інших осіб. Законне використання матеріалів, дозволене законодавством, не обмежується цією Угодою.',
      ] },
      { id: 'data', title: '7. Які дані обробляються і для чого', paragraphs: [
        'Магазин обробляє надані користувачем ім’я, телефон, email за наявності, місто та реквізити доставки, склад і історію замовлень, статуси оплат і відправлень, повернення та звернення. Також обробляються ідентифікатори акаунта і сесії, запис прийняття Угоди та технічні дані запитів, необхідні для роботи й безпеки сервісу, зокрема IP-адреса, дані браузера та час запиту.',
        'Цілі — реєстрація і вхід, виконання замовлень, доставка, оплата та повернення коштів, підтримка покупця, облік, запобігання шахрайству і виконання законних обов’язків. Підставою є укладення та виконання договору, вимоги закону, законні інтереси з урахуванням прав людини, а коли це потрібно — окрема згода. Обробка обмежується даними, необхідними для відповідної мети.',
        'Погодження з Угодою не є згодою на рекламні SMS, email-розсилки або передачу даних для чужого маркетингу. Для реклами, коли цього вимагає закон, потрібна окрема добровільна згода; відмова від неї не перешкоджає реєстрації або покупкам. SMS-коди й повідомлення щодо конкретного замовлення мають сервісне призначення.',
      ] },
      { id: 'services', title: '8. Зовнішні сервіси та одержувачі даних', paragraphs: [
        'Для роботи магазину використовуються або можуть підключатися перелічені нижче сервіси. Альтернативні SMS- та платіжні провайдери отримують дані лише тоді, коли відповідний провайдер фактично обраний або використовується для операції. Перелік не означає передачі всіх даних кожному сервісу.',
        'Обсяг передачі визначається функцією сервісу: дані акаунта й замовлення — для зберігання та обслуговування; телефон і код — для SMS; потрібні відомості про отримувача та посилку — для перевезення; сума, опис і ідентифікатори операції — для оплати. Банки та перевізники можуть також самостійно обробляти дані для виконання власних законних обов’язків.',
        'Умови відповідного провайдера застосовуються до його послуг, але не замінюють обов’язків продавця перед покупцем. Позначення чекбокса не є автоматичним укладенням усіх договорів із третіми особами та не дозволяє необмежену передачу даних.',
      ] },
      { id: 'storage', title: '9. Локальні налаштування та SMS-автопідстановка', paragraphs: [
        'Браузер зберігає необхідні для роботи кошик, дані сесії, вибрану мову, тему та технічні позначки оформлення й оплати. Для цього можуть використовуватися localStorage, sessionStorage і технічні cookie залучених сервісів. Після очищення сховища можуть зникнути налаштування, незавершений кошик або вхід у систему.',
        'Автопідстановка коду відбувається засобами операційної системи чи браузера, зокрема WebOTP за підтримки та дозволу користувача. Магазин отримує лише код для поточного входу; ручне введення залишається доступним. Необов’язкові рекламні трекери не включаються на підставі цієї Угоди; якщо їх буде запроваджено, буде надана відповідна інформація і, де потрібно, окремий вибір.',
      ] },
      { id: 'retention', title: '10. Зберігання, захист і міжнародна передача', paragraphs: [
        'Дані зберігаються протягом часу, потрібного для обслуговування акаунта і договору, розгляду претензій та обов’язкового обліку. Після закінчення відповідної мети і встановлених законом строків дані видаляються або знеособлюються. Видалення акаунта не завжди означає негайне видалення документів щодо вже здійсненої покупки, які закон зобов’язує зберігати.',
        'Хмарні постачальники можуть обробляти дані за межами України. Продавець має забезпечити належні правові підстави такої передачі та захист даних відповідно до законодавства України; ця Угода не є дозволом передавати дані до будь-якої країни без необхідних гарантій. Відомості про одержувачів і місце обробки можна запитати у продавця.',
        'Для захисту використовуються розмежування доступу, захищені з’єднання та засоби автентифікації. Користувач також повинен захищати телефон, пристрій і коди входу. Жодне положення не звільняє продавця від відповідальності за порушення обов’язків із захисту даних.',
      ] },
      { id: 'rights', title: '11. Права щодо персональних даних', paragraphs: [
        'Користувач має передбачені законом права знати мету та одержувачів обробки, отримувати доступ до своїх даних, вимагати виправлення недостовірних даних, заперечувати проти незаконної обробки, вимагати видалення у встановлених випадках та відкликати згоду щодо обробки, що ґрунтується саме на згоді. Відкликання не скасовує попередню правомірну обробку і законні обов’язки щодо зберігання.',
        'Запити надсилаються на tatami.culture@gmail.com. Для захисту даних продавець може перевірити особу заявника в обсязі, необхідному для запиту. Користувач має право звернутися до Уповноваженого Верховної Ради України з прав людини або до суду.',
      ] },
      { id: 'liability', title: '12. Відповідальність та вирішення спорів', paragraphs: [
        'Сторони відповідають за свої дії відповідно до закону. Технічні перерви, збої оператора, банку або перевізника можуть впливати на доступність окремих функцій, однак саме залучення зовнішнього сервісу не усуває зобов’язань продавця щодо замовлення, повернення коштів чи законних прав споживача.',
        'Про проблему слід повідомити продавця, щоб узгодити її вирішення. Це не позбавляє права звертатися до компетентних органів або суду без обов’язкового досудового врегулювання, якщо закон його не вимагає. Обставини непереборної сили оцінюються у порядку, визначеному законом; вони не створюють автоматичного права залишити оплату за непоставлений товар.',
      ] },
      { id: 'changes', title: '13. Редакції Угоди', paragraphs: [
        'Чинна редакція та дата оприлюднюються на цій сторінці. Зміни застосовуються до майбутніх відносин і не змінюють заднім числом погоджену ціну, права щодо вже оформленого замовлення або обсяг раніше наданої згоди. Якщо закон вимагає нового погодження, його отримують окремо.',
        'Український текст є основним; англійський переклад надано для зручності. У разі суперечності застосовується українська редакція з урахуванням обов’язкових вимог законодавства.',
      ] },
    ] satisfies Section[],
  },
  en: {
    title: 'User agreement',
    subtitle: 'Store terms, purchases and personal data processing',
    sections: [
      { id: 'general', title: '1. General terms and seller', paragraphs: [
        'This Agreement governs use of tatami.culture, account creation, purchases and personal data processing. The seller and personal data controller is ФОП Яковішина Дарʼя Андріївна, Ukrainian individual taxpayer registration number 3620003508. Registered address: Ukraine, Kryvyi Rih, Dniprovske Shose, building 36, apartment 117. Contact: tatami.culture@gmail.com. The store’s current Instagram account, linked below, is an additional contact channel.',
        'Ukrainian law applies, including electronic commerce, consumer protection and personal data legislation. Mandatory consumer rights prevail over this Agreement. Creating an account does not require a purchase.',
      ] },
      { id: 'account', title: '2. Registration and account security', paragraphs: [
        'To register, provide an accurate name and phone number, actively accept this Agreement and verify control of the number with an SMS code. Do not share codes or use another person’s details without proper authority.',
        'We record the Agreement version accepted and the time of acceptance. SMS autofill depends on the browser and device permissions and does not give the store access to other messages. Contact the seller if you lose your phone number or suspect unauthorised access.',
        'Users must have the legal capacity required for their actions. Where required by law, minors must act with the involvement or consent of a legal representative.',
      ] },
      { id: 'orders', title: '3. Products and orders', paragraphs: [
        'The catalogue shows product descriptions, sizes, prices and availability. Check your items, contact details, delivery destination and payment method before submitting an order. Screen settings may affect colours in photographs; products must still conform to their description.',
        'A purchase contract is formed when the seller confirms the order, including automated confirmation of an accepted paid order. Confirmation states the items and price. If a price is incorrect or stock is unavailable, the seller contacts you; changes to items, price or timing require agreement. Payments for orders that cannot be fulfilled must be refunded in accordance with law.',
        'Dispatch dates for preorders or items ordered from a supplier are agreed before payment. An option to order an out-of-stock item does not mean that it is immediately available.',
      ] },
      { id: 'payment', title: '4. Prices, payment and delivery', paragraphs: [
        'Product prices, available discounts and the order total are shown before confirmation. Any separate delivery or cash-on-delivery charge depends on the selected service and is disclosed before checkout is completed. Payments to the seller are in Ukrainian hryvnia; indicative currency conversions do not change the agreed amount.',
        'Available payment methods appear at checkout. Online payment takes place with the payment provider. Card details and CVV are entered on the provider’s side and are not stored by the store. Payment is confirmed by the provider, not merely by returning to the website. The seller provides the payment document required by law; the order page is not a substitute for a fiscal receipt where one is required.',
        'Orders are delivered by the method selected at checkout, including Nova Poshta. The buyer is informed of dispatch timing and estimated transit time. Inspect the packaging and goods on receipt and, where possible, record damage with the carrier. Failure to obtain such a record does not by itself remove statutory consumer rights.',
      ] },
      { id: 'returns', title: '5. Cancellations, exchanges, returns and defects', paragraphs: [
        'For a cancellation, exchange, return or defect claim, email tatami.culture@gmail.com with the order number and a description of the issue. The seller will provide the return address and instructions. Do not send goods to an unconfirmed branch.',
        'Goods of satisfactory quality may be exchanged within the statutory period, generally 14 days excluding the purchase date, subject to statutory conditions including unused condition, preserved appearance, properties, seals, labels and proof of purchase. Distance contracts also carry statutory withdrawal rights, with their applicable starting dates, time limits and exceptions.',
        'Exceptions for particular categories of satisfactory-quality goods apply only where the law provides them. Sports clothing is not automatically excluded. For defective goods, statutory rights may include repair, replacement, a price reduction or refund as applicable. A discount does not remove these rights.',
        'Refund procedures, deadlines and responsibility for return shipping follow the law and the reason for the return. The seller explains the process before return shipment and does not impose arbitrary deductions that restrict mandatory rights.',
      ] },
      { id: 'use', title: '6. Website use and intellectual property', paragraphs: [
        'The website design, text, photographs and marks belong to their respective rights holders. Users receive non-exclusive permission to browse, make personal purchases and manage their orders. This does not transfer trademark rights or a right to reproduce materials commercially.',
        'Unauthorised access, interference with payments or inventory, fraudulent orders, malicious code and violations of others’ rights are prohibited. Uses permitted by law remain permitted.',
      ] },
      { id: 'data', title: '7. Personal data and purposes', paragraphs: [
        'The store processes the name, phone, optional email, delivery destination, order contents and history, payment and shipment statuses, returns and support enquiries you provide. Processing also includes account and session identifiers, the acceptance record and technical request data needed for operation and security, such as IP address, browser information and request time.',
        'Purposes include account access, order fulfilment, shipping, payments and refunds, support, accounting, fraud prevention and legal compliance. Applicable grounds include entering into and performing a contract, legal duties, legitimate interests balanced against individual rights and, where required, separate consent. Processing is limited to what is necessary for its purpose.',
        'Accepting this Agreement is not consent to advertising SMS, email campaigns or another party’s marketing. Marketing requires separate voluntary consent where required by law; refusing it does not prevent registration or purchases. Login codes and communications about a specific order are service messages.',
      ] },
      { id: 'services', title: '8. External services and recipients', paragraphs: [
        'The services listed below are used or supported by the store. Alternative SMS and payment providers receive data only when actually selected or involved in the relevant transaction. Listing them does not mean that all information is shared with every provider.',
        'Data shared depends on the service: account and order data for storage and operation; a phone number and code for SMS; necessary recipient and parcel details for delivery; amount, description and transaction identifiers for payment. Banks and carriers may also process data independently to meet their own legal duties.',
        'Provider terms apply to their services but do not replace the seller’s duties to the buyer. Checking the registration box does not automatically enter you into every third-party contract or authorise unlimited disclosure.',
      ] },
      { id: 'storage', title: '9. Browser storage and SMS autofill', paragraphs: [
        'The browser stores the cart, session information, language, theme and technical checkout/payment markers needed for the service. This may use localStorage, sessionStorage and technical cookies from involved services. Clearing storage may remove preferences, an unfinished cart or your login.',
        'The operating system or browser provides SMS autofill, including WebOTP where supported and permitted. The store receives only the relevant login code; manual entry remains available. This Agreement does not enable optional advertising trackers. Any future introduction requires appropriate information and, where required, a separate choice.',
      ] },
      { id: 'retention', title: '10. Retention, security and international transfers', paragraphs: [
        'Data is kept for the time necessary to service the account and contract, handle claims and fulfil statutory recordkeeping. It is deleted or anonymised when its purpose and applicable legal retention periods end. Account deletion does not necessarily immediately delete purchase records that must legally be retained.',
        'Cloud providers may process data outside Ukraine. The seller must ensure a lawful basis and appropriate safeguards under Ukrainian law; this Agreement does not authorise unrestricted transfers to any country. Ask the seller for information about recipients and processing locations.',
        'Security measures include restricted access, protected connections and authentication. Users should also protect their phones, devices and login codes. These terms do not exclude the seller’s liability for breaches of data protection duties.',
      ] },
      { id: 'rights', title: '11. Your personal data rights', paragraphs: [
        'Subject to law, you may learn the purposes and recipients of processing, access your data, request corrections, object to unlawful processing, request deletion where applicable and withdraw consent for processing based on consent. Withdrawal does not invalidate previous lawful processing or statutory retention duties.',
        'Send requests to tatami.culture@gmail.com. The seller may verify identity to the extent needed to protect the data. You may complain to the Ukrainian Parliament Commissioner for Human Rights or seek judicial protection.',
      ] },
      { id: 'liability', title: '12. Liability and disputes', paragraphs: [
        'Each party is responsible under applicable law. Interruptions and faults at an operator, bank or carrier may affect particular functions, but using an external provider does not remove the seller’s duties concerning orders, refunds or statutory consumer rights.',
        'Contact the seller to help resolve a problem. You retain access to competent authorities and courts without mandatory prior negotiation unless required by law. Force majeure is assessed under law and does not automatically entitle the seller to retain payment for undelivered goods.',
      ] },
      { id: 'changes', title: '13. Agreement versions', paragraphs: [
        'The current version and date are published on this page. Changes apply prospectively and do not retrospectively change agreed prices, rights relating to existing orders or the scope of earlier consent. Fresh acceptance is obtained separately where legally required.',
        'The Ukrainian text is authoritative; this English translation is provided for convenience. In case of a difference, the Ukrainian version applies, subject to mandatory legal requirements.',
      ] },
    ] satisfies Section[],
  },
}
