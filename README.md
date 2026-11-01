# Tatami store

Небольшой интернет-магазин спортивной одежды на React + TypeScript. Витрина работает и без backend в демо-режиме, а при наличии переменных окружения автоматически использует Supabase.

## Запуск

```bash
cd store
yarn dev
```

Без `.env.local` используется локальный каталог и `localStorage`; это удобно для интерфейсной разработки. Демо-витрина доступна по `/tatami`.

## Подключение Supabase

1. Создать проект Supabase и применить [миграцию](supabase/migrations/20261008000000_store_crm.sql) через SQL Editor или Supabase CLI.
2. Выполнить [seed.sql](supabase/seed.sql), чтобы добавить Tatami и стартовый каталог.
3. Скопировать `.env.example` в `.env.local` и добавить URL проекта и **anon key**. `service_role` ключ никогда не добавляется в Vite.
4. Создать собственный аккаунт в витрине и назначить его владельцем, выполнив запрос из конца миграции.

Цены в базе хранятся в копейках; frontend переводит их в гривны при отображении. Создание заказа выполняется функцией `create_store_order`: она повторно проверяет наличие, берёт текущую цену и атомарно уменьшает остаток.

## CRM в Supabase

В схеме предусмотрены заказы и позиции заказа, профили покупателей, заметки, теги, история статусов, роли команды и привязка сотрудников к магазину. RLS открывает только активный каталог публично, покупателю — его собственные заказы, а менеджеру — данные только его магазина.

Первый безопасный релиз не включает платёжный ключ в браузер: оплату и доставку следует добавлять следующими server-side Edge Functions после выбора провайдера.

## LiqPay checkout

Для украинского бизнеса проект подготовлен к LiqPay hosted checkout. Карточные данные не попадают в приложение: Edge Function создаёт подписанную ссылку на страницу LiqPay, а отдельный webhook меняет статус заказа только после callback от провайдера.

1. Применить [миграцию платежей](supabase/migrations/20261031010000_payments.sql).
2. В Supabase Edge Function Secrets добавить `LIQPAY_PUBLIC_KEY`, `LIQPAY_PRIVATE_KEY` и `SITE_URL` (адрес опубликованного магазина без завершающего `/`).
3. Развернуть `liqpay-create-checkout` и `liqpay-webhook` из `supabase/functions/`. Для webhook уже задано отключение JWT-проверки в `supabase/config.toml`, а сам callback проверяется криптографической подписью LiqPay.
4. В `.env.local` задать `VITE_LIQPAY_ENABLED=true` и перезапустить Vite.

Через CLI это выглядит так:

```bash
supabase link --project-ref YOUR_PROJECT_REF
supabase secrets set LIQPAY_PUBLIC_KEY=... LIQPAY_PRIVATE_KEY=... SITE_URL=https://your-domain.example
supabase functions deploy liqpay-create-checkout --use-api
supabase functions deploy liqpay-webhook --use-api
```

До включения `VITE_LIQPAY_ENABLED` checkout сохраняет прежний demo-режим и не проводит настоящую оплату.

## Monobank

1. Apply migration `supabase/migrations/20261031030000_monobank_payments.sql`.
2. Add `MONOBANK_TOKEN` to Supabase Edge Function Secrets. Keep this merchant token private.
3. Deploy `monobank-create-invoice` and `monobank-webhook` functions.
4. Set `VITE_MONOBANK_ENABLED=true` in `.env.local`, then restart Vite.

Checkout creates a Monobank invoice, opens its returned `pay.mbnk.biz` page and confirms the final payment state with Monobank before marking an order as paid.

## Nova Poshta

1. Generate an API 2.0 key in the Nova Poshta business cabinet and add it to Supabase Edge Function Secrets as `NOVA_POSHTA_API_KEY`. For test TTN, add the separate stage key as `NOVA_POSHTA_TEST_API_KEY`.
2. Deploy `nova-poshta-directory` and `nova-poshta-create-ttn`.
3. Set `VITE_NOVAPOSHTA_ENABLED=true` in `.env.local`, then restart Vite.

Checkout will then search Nova Poshta cities and require a selected branch or parcel locker. The selected city and branch are saved in the existing delivery fields of the order.

In CRM → Settings, choose the sender and parcel defaults, then select test or live mode. In CRM → Orders, a manager can issue a TTN for a non-cancelled order; its number is saved on the order and opens the public tracking page. A Nova Poshta sender/counterparty with the configured sender name and city must already exist in the selected API-key account.

### Тестовый режим LiqPay

1. В кабинете LiqPay включить тестовый режим и использовать пару ключей с префиксом `sandbox_`.
2. В Edge Function Secrets установить `LIQPAY_TEST_MODE=true` вместе с тестовыми ключами и развернуть функции.
3. В `.env.local` задать `VITE_LIQPAY_ENABLED=true`, затем перезапустить Vite.
4. Оформить заказ и на странице LiqPay использовать тестовую карту `4242 4242 4242 4242`, любую будущую дату и любой трёхзначный CVV.

Тестовый callback имеет статус `sandbox`; функция обработает его как успешную тестовую оплату и переведёт заказ в `PAID`. Перед настоящими оплатами замените ключи на боевые, установите `LIQPAY_TEST_MODE=false` и заново разверните функции.
