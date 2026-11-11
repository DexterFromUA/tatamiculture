# Tatami store

Интернет-магазин спортивной одежды на React + TypeScript с данными в Supabase.

## Запуск

```bash
cd store
yarn dev
```

Перед запуском настрой `VITE_SUPABASE_URL` и `VITE_SUPABASE_ANON_KEY` в `.env.local`. Для опубликованной витрины задай эти же переменные в настройках сборки. При отсутствии конфигурации витрина показывает сообщение о недоступности магазина.

## Подключение Supabase

1. Создать проект Supabase и применить [миграцию](supabase/migrations/20261008000000_store_crm.sql) через SQL Editor или Supabase CLI.
2. Выполнить [seed.sql](supabase/seed.sql), чтобы добавить магазин Tatami. Каталог заполняется в CRM.
3. Скопировать `.env.example` в `.env.local` и добавить URL проекта и **anon key**. `service_role` ключ никогда не добавляется в Vite.
4. Создать собственный аккаунт в витрине и назначить его владельцем, выполнив запрос из конца миграции.

Цены в базе хранятся в копейках; frontend переводит их в гривны при отображении. Создание заказа выполняется функцией `create_store_order`: она повторно проверяет наличие, берёт текущую цену и атомарно уменьшает остаток.

## CRM в Supabase

В схеме предусмотрены заказы и позиции заказа, профили покупателей, заметки, теги, история статусов, роли команды и привязка сотрудников к магазину. RLS открывает только активный каталог публично, покупателю — его собственные заказы, а менеджеру — данные только его магазина.

Первый безопасный релиз не включает платёжный ключ в браузер: оплату и доставку следует добавлять следующими server-side Edge Functions после выбора провайдера.

## LiqPay checkout

Для украинского бизнеса проект подготовлен к LiqPay hosted checkout. Карточные данные не попадают в приложение: Edge Function создаёт подписанную ссылку на страницу LiqPay, а отдельный webhook меняет статус заказа только после callback от провайдера.

1. Применить [миграцию платежей](supabase/migrations/20261031010000_payments.sql).
2. В Supabase Edge Function Secrets добавить тестовую пару `LIQPAY_PUBLIC_KEY` и `LIQPAY_PRIVATE_KEY` с префиксом `sandbox_`, боевую пару `LIQPAY_LIVE_PUBLIC_KEY` и `LIQPAY_LIVE_PRIVATE_KEY` и `SITE_URL` (адрес опубликованного магазина без завершающего `/`).
3. Развернуть `liqpay-create-checkout` и `liqpay-webhook` из `supabase/functions/`. Для webhook уже задано отключение JWT-проверки в `supabase/config.toml`, а сам callback проверяется криптографической подписью LiqPay.
4. В `.env.local` задать `VITE_LIQPAY_ENABLED=true` и перезапустить Vite.

Через CLI это выглядит так:

```bash
supabase link --project-ref YOUR_PROJECT_REF
supabase secrets set LIQPAY_PUBLIC_KEY=... LIQPAY_PRIVATE_KEY=... LIQPAY_LIVE_PUBLIC_KEY=... LIQPAY_LIVE_PRIVATE_KEY=... SITE_URL=https://your-domain.example
supabase functions deploy liqpay-create-checkout --use-api
supabase functions deploy liqpay-webhook --use-api
```

До включения `VITE_LIQPAY_ENABLED` способ оплаты LiqPay скрыт при оформлении заказа.

## Monobank

1. Apply the Supabase migrations with the CLI.
2. Set `MONOBANK_TOKEN` to the live acquiring token and `MONOBANK_TEST_TOKEN` to a separate test token from [Monobank's API portal](https://api.monobank.ua/) in Supabase Edge Function Secrets.
3. Deploy `monobank-create-invoice` and `monobank-webhook` functions.
4. Set `VITE_MONOBANK_ENABLED=true` in `.env.local`, then restart Vite.

Checkout creates a Monobank invoice, opens its returned `pay.mbnk.biz` page and confirms the final payment state with Monobank before marking an order as paid.

## Payment mode

Deploy `set-payment-mode` along with the checkout and webhook functions. In CRM → Settings → Payments, the **Test mode** switch saves immediately and controls new Monobank and LiqPay checkouts. A mode change requires the corresponding credentials for every enabled online provider. Until the first switch, existing stores keep their previous provider settings, including `LIQPAY_TEST_MODE`. Keep the original LiqPay pair available to verify callbacks for orders created before the switch was introduced.

Each new order keeps its mode for webhook verification. Test orders are labeled and excluded from stock reservations and revenue. TTN creation uses the separate Nova Poshta delivery settings.

## Nova Poshta

1. Generate an API 2.0 key in the Nova Poshta business cabinet and add it to Supabase Edge Function Secrets as `NOVA_POSHTA_API_KEY`.
2. Deploy `nova-poshta-directory`, `nova-poshta-create-ttn` and `nova-poshta-track-ttn`.
3. Set `VITE_NOVAPOSHTA_ENABLED=true` in `.env.local`, then restart Vite.

Checkout will then search Nova Poshta cities and require a selected branch or parcel locker. The selected city and branch are saved in the existing delivery fields of the order.

In CRM → Settings, choose the sender and parcel defaults. In CRM → Orders, a manager can issue a TTN for a non-cancelled order. Its number is saved on the order and opens the public tracking page. A Nova Poshta sender/counterparty with the configured sender name and city must already exist in the account associated with `NOVA_POSHTA_API_KEY`.

### Тестовый режим LiqPay

1. Скопировать ключи с префиксом `sandbox_` из кабинета LiqPay в тестовую пару Supabase.
2. Включить тестовый режим в CRM → Настройки → Оплата.
3. Оформить заказ и на странице LiqPay использовать тестовую карту `4242 4242 4242 4242`, любую будущую дату и любой трёхзначный CVV.

Подписанный статус `sandbox` переводит тестовый заказ в `PAID`. После добавления боевой пары ключей для приёма реальных платежей выключите переключатель в CRM.

## Вход через SMS

Twilio настраивается в Supabase Authentication → Phone. Supabase Auth выдаёт и проверяет коды для обоих провайдеров.

1. В Supabase Edge Function Secrets укажи `KYIVSTAR_CLIENT_ID` и `KYIVSTAR_CLIENT_SECRET` из [кабинета API Киевстара](https://api-market.kyivstar.ua/). Пока `KYIVSTAR_SMS_FROM` не содержит согласованного альфа-имени, коды входа через Киевстар отправляются из песочницы от `messagedesk` на подтверждённые в кабинете номера. После добавления альфа-имени используется боевой API.
2. В `SMS_AUTH_MANAGEMENT_TOKEN` укажи [scoped access token](https://supabase.com/dashboard/account/tokens) только для проекта Tatami с правами **Auth Config** и **Project Settings** на чтение и запись. `SMS_AUTH_HOOK_SECRET` содержит отдельный секрет подписи хука в формате `v1,whsec_<base64>`.
3. В CRM → Настройки → Вход через SMS переключись на Киевстар. CRM включает подписанный **Send SMS Hook** для Киевстара и выключает его при выборе встроенного Twilio.
4. Проверь вход с обычного номера для обоих провайдеров. Номера из списка тестовых OTP в Supabase обходят отправку SMS.

Для проверки доставки до согласования альфа-имени добавь и подтверди номер в разделе **Пісочниця** в кабинете Киевстара. В CRM → Настройки → Вход через SMS → Пісочниця Київстар отправь тестовое сообщение на этот номер. Этот запрос использует песочницу и имя `messagedesk`.
