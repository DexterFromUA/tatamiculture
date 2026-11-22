# Tatami store

Интернет-магазин спортивной одежды на React + TypeScript с данными в Supabase.

## Запуск

```bash
cd store
yarn dev
```

Перед запуском настрой `VITE_SUPABASE_URL` и `VITE_SUPABASE_ANON_KEY` в `.env.local`. Для опубликованной витрины задай эти же переменные в настройках сборки. При отсутствии конфигурации витрина показывает сообщение о недоступности магазина.

## Подключение Supabase

1. Создать проект Supabase и выполнить [bootstrap.sql](supabase/bootstrap.sql). Скрипт создаст схему и единственную запись настроек магазина в `shop_settings`. Каталог заполняется в CRM.
2. Скопировать `.env.example` в `.env.local` и добавить URL проекта и **anon key**. `service_role` ключ никогда не добавляется в Vite.
3. Зарегистрировать аккаунт, подставить его **User UID** в [seed-owner.sql](supabase/seed-owner.sql) и выполнить файл в SQL Editor, чтобы назначить владельца CRM.
4. Привязать проект через `supabase link` и применить миграции после bootstrap командой `supabase db push`.

Цены в базе хранятся в копейках. При заказе с наложенным платежом `create_discounted_store_order` проверяет наличие, берёт текущую цену и атомарно уменьшает остаток. Онлайн-заказ создаётся после подтверждения платежа.

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

Each invoice keeps its acquiring mode for webhook verification and provider refunds. Orders use the same fulfilment, inventory and CRM workflow in either payment mode. TTN creation uses the configured Nova Poshta business account.

## Nova Poshta

1. Generate an API 2.0 key in the Nova Poshta business cabinet and add it to Supabase Edge Function Secrets as `NOVA_POSHTA_API_KEY`.
2. Deploy `nova-poshta-directory`, `nova-poshta-create-ttn` and `nova-poshta-track-ttn`.
3. Set `VITE_NOVAPOSHTA_ENABLED=true` in `.env.local`, then restart Vite.

Checkout will then search Nova Poshta cities and require a selected branch or parcel locker. The selected city and branch are saved in the existing delivery fields of the order.

In CRM → Settings, choose the sender and parcel defaults. In CRM → Orders, a manager can issue a TTN starting at Preparing for shipment. Its number is saved on the order and opens the public tracking page. A Nova Poshta sender/counterparty with the configured sender name and city must already exist in the account associated with `NOVA_POSHTA_API_KEY`.

After applying the order workflow migrations and deploying the updated tracking function, set the linked project's URL once to enable tracking every two hours:

```sh
supabase db query --remote --yes "update public.nova_poshta_tracking_schedule set project_url = 'https://PROJECT_REF.supabase.co' where singleton"
```

Deploy `crm-refund-order` and the updated Monobank and LiqPay webhooks after the refund migration. Automatic refunds use the original online payment. If the provider has not confirmed the result, staff can check the status again from the order card.

### Тестовый режим LiqPay

1. Скопировать ключи с префиксом `sandbox_` из кабинета LiqPay в тестовую пару Supabase.
2. Включить тестовый режим в CRM → Настройки → Оплата.
3. Оформить заказ и на странице LiqPay использовать тестовую карту `4242 4242 4242 4242`, любую будущую дату и любой трёхзначный CVV.

Подписанный статус `sandbox` переводит тестовый заказ в `PAID`. После добавления боевой пары ключей для приёма реальных платежей выключите переключатель в CRM.

## Вход через SMS

Провайдер кодов входа и регистрации выбирается в **CRM → Настройки → SMS**.

- **Twilio** настраивается в Supabase Authentication → Phone.
- **Киевстар** использует `KYIVSTAR_CLIENT_ID`, `KYIVSTAR_CLIENT_SECRET` из [кабинета API](https://api-market.kyivstar.ua/) и согласованное имя `KYIVSTAR_SMS_FROM`. До согласования имени коды отправляются через песочницу на подтверждённые в кабинете номера.
- **SMSClub (smsclub.com.ua)** использует ключ HTTP API из настроек кабинета `SMSCLUB_API_TOKEN` и согласованное альфа-имя `SMSCLUB_SMS_FROM`. [Документация SMSClub](https://smsclub.com.ua/uk/bulksms/techdocs)

Секреты Киевстара и SMSClub синхронизируются из Infisical (`prod`, `/supabase`) в Supabase Edge Function Secrets. `SMS_AUTH_MANAGEMENT_TOKEN` содержит [токен проекта Tatami](https://supabase.com/dashboard/account/tokens) с доступом к конфигурации Auth, а `SMS_AUTH_HOOK_SECRET` — секрет подписи в формате `v1,whsec_<base64>`. CRM включает **Send SMS Hook** для Киевстара и SMSClub. При выборе Twilio Supabase использует встроенную интеграцию.

Номера из списка тестовых OTP в Supabase обходят отправку SMS. Доставку кодов проверяют на обычном номере.
