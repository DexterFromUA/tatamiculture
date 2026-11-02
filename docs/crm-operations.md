# CRM operations

Migration: `supabase/migrations/20261102201144_crm_operations.sql`, created and applied with Supabase CLI.
Internal journal visibility is tightened by `20261102202118_crm_event_visibility.sql`: direct access is staff-only; customers use the receipt RPC's restricted projection.

## Where to find features

- CRM → Orders: 20 orders per page. CSV exports every order matching the active search, status and date filters, rather than only the visible page. Data is fetched in API batches to avoid the PostgREST result cap.
- CRM → Customers: name/phone search, 20 customers per page, CSV for all matching customers.
- CRM → Catalogue: name/SKU search and 20 products per page.
- Order → Events and finances: audit history, order cost in the order currency, confirmed return amount and reason. Only delivered orders can have a recorded return; cumulative returns cannot exceed the order total. Recording a return does not call a payment provider or change inventory.
- CRM → Overview: repeat customers, net delivered revenue, return amounts/rate, gross margin and cost coverage, grouped by currency. Repeat customers use paid or delivered non-cancelled orders and normalized phone, email, or user ID. Unknown costs are excluded from margin, not treated as zero. Costs are entered per order. Margin excludes commissions, taxes, shipping expenses and overhead; returned amounts are subtracted conservatively without estimating recovered inventory value.
- Account: latest 50 notifications, unread markers, mark-as-read. Refreshes every 30 seconds while the account screen is open. Guests can see customer-visible events on their receipt link. No external email/SMS order notifications are configured.
- Receipt: customer-visible status, payment and return timeline. Internal costs and author IDs are not exposed through receipt lookup.

## Password recovery

`/forgot-password` sends the standard Supabase recovery email. The callback is `/reset-password`, uses the implicit recovery token fragment and removes it from the address bar. The token is kept only in component memory. Reloading the cleared callback requires a fresh link. New passwords require at least eight characters and confirmation. Existing local auth state is cleared after success; sign in again with the new password.

Add the actual site origin + `/reset-password` to Supabase Auth → URL Configuration → Redirect URLs (including `http://localhost:5173/reset-password` for local use). Supabase email delivery/SMTP settings must be operational. The page does not pretend to recover mock accounts.

## Validation

- `yarn build`
- `yarn node --test tests/analytics.test.mjs`
- `yarn node tests/crm-access.mjs` — read-only checks against `.env.local` public API, never prints credentials.
- Targeted ESLint on changed source files. Global lint currently also reports pre-existing errors in context modules, CheckoutPage, DeliverySettingsPage and liqpay-webhook; these integrations were left unchanged.

Remaining live checks: authenticated manager/customer workflows and delivery of an actual password-reset email. Nova Poshta and monobank adapters/settings were not changed in this work.
