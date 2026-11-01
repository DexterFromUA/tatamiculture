import { createClient } from 'npm:@supabase/supabase-js@2'

type NovaData = Record<string, unknown>

const cors = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type' }
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors })

function nameParts(fullName: string) {
  const parts = fullName.trim().split(/\s+/).filter(Boolean)
  return { lastName: parts[0] ?? 'Клієнт', firstName: parts[1] ?? parts[0] ?? 'Клієнт', middleName: parts.slice(2).join(' ') }
}

function dateForNovaPost() {
  const now = new Date()
  return `${String(now.getDate()).padStart(2, '0')}.${String(now.getMonth() + 1).padStart(2, '0')}.${now.getFullYear()}`
}

async function novaPost(apiKey: string, modelName: string, calledMethod: string, methodProperties: NovaData) {
  const response = await fetch('https://api.novaposhta.ua/v2.0/json/', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ apiKey, modelName, calledMethod, methodProperties }),
  })
  const result = await response.json() as { success?: boolean; data?: NovaData[]; errors?: string[]; warnings?: string[] }
  if (!response.ok || !result.success) throw new Error(result.errors?.join(', ') || result.warnings?.join(', ') || 'Nova Poshta request failed')
  return result.data ?? []
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return json({ error: 'Supabase is not configured' }, 503)

  try {
    const { orderId } = await request.json() as { orderId?: string }
    if (!orderId) throw new Error('Order is required')
    const authorization = request.headers.get('Authorization') ?? `Bearer ${anonKey}`
    const authClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } } })
    const { data: userData, error: userError } = await authClient.auth.getUser()
    if (userError || !userData.user) return json({ error: 'Sign in as a store manager first' }, 401)
    const db = createClient(supabaseUrl, serviceRoleKey)
    const { data: order, error: orderError } = await db.from('orders').select('*').eq('id', orderId).maybeSingle()
    if (orderError || !order) return json({ error: 'Order was not found' }, 404)
    const { data: membership } = await db.from('store_members').select('role').eq('store_id', order.store_id).eq('user_id', userData.user.id).maybeSingle()
    if (!membership) return json({ error: 'You do not have access to this order' }, 403)
    if (String(order.status).startsWith('CANCELLED')) throw new Error('A TTN cannot be created for a cancelled order')
    if (order.nova_poshta_ttn) return json({ ttn: order.nova_poshta_ttn, documentRef: order.nova_poshta_document_ref, existing: true })
    if (!order.delivery_city_ref || !order.delivery_address_ref) throw new Error('This order lacks Nova Poshta branch references. Create a new order after enabling delivery, or set its destination again.')

    const { data: settings, error: settingsError } = await db.from('delivery_settings').select('*').eq('store_id', order.store_id).maybeSingle()
    if (settingsError || !settings) throw new Error('Configure Nova Poshta sender settings first')
    if (!settings.sender_name || !settings.sender_phone || !settings.city_ref || !settings.warehouse_ref) throw new Error('Fill in sender name, phone, city and dispatch branch in Nova Poshta settings')
    const apiKey = settings.nova_post_test_mode ? Deno.env.get('NOVA_POSHTA_TEST_API_KEY')?.trim() : Deno.env.get('NOVA_POSHTA_API_KEY')?.trim()
    if (!apiKey) throw new Error(settings.nova_post_test_mode ? 'NOVA_POSHTA_TEST_API_KEY is not configured' : 'NOVA_POSHTA_API_KEY is not configured')

    const senders = await novaPost(apiKey, 'Counterparty', 'getCounterparties', { CounterpartyProperty: 'Sender', FindByString: settings.sender_name, CityRef: settings.city_ref, Page: '1', Limit: '20' })
    const sender = senders.find((item) => String(item.Description ?? '').trim().toLowerCase() === String(settings.sender_name).trim().toLowerCase()) ?? senders[0]
    if (!sender?.Ref) throw new Error('Nova Poshta sender was not found for the configured name and city')
    let contactSender = (sender.ContactPerson as { data?: NovaData[] } | undefined)?.data?.[0]?.Ref
    if (!contactSender) {
      const contacts = await novaPost(apiKey, 'Counterparty', 'getCounterpartyContactPersons', { Ref: sender.Ref, Page: '1' })
      contactSender = contacts[0]?.Ref
    }
    if (!contactSender) throw new Error('Nova Poshta sender contact was not found')

    const person = nameParts(String(order.customer_name))
    const recipients = await novaPost(apiKey, 'Counterparty', 'save', {
      FirstName: person.firstName, MiddleName: person.middleName, LastName: person.lastName,
      Phone: String(order.customer_phone).replace(/\D/g, ''), Email: String(order.customer_email),
      CounterpartyType: 'PrivatePerson', CounterpartyProperty: 'Recipient', CityRef: order.delivery_city_ref,
    })
    const recipient = recipients[0]
    const recipientContact = (recipient?.ContactPerson as { data?: NovaData[] } | undefined)?.data?.[0]?.Ref
    if (!recipient?.Ref || !recipientContact) throw new Error('Nova Poshta could not create the recipient')

    const weightKg = Math.max(0.1, Number(settings.default_weight_grams) / 1000)
    const document = (await novaPost(apiKey, 'InternetDocument', 'save', {
      PayerType: settings.delivery_payer === 'SENDER' ? 'Sender' : 'Recipient', PaymentMethod: 'Cash',
      DateTime: dateForNovaPost(), CargoType: 'Parcel', Weight: String(weightKg), SeatsAmount: '1',
      Description: `Tatami order ${order.receipt_code}`, Cost: String(Math.max(1, Math.round(Number(settings.declared_value)))),
      CitySender: settings.city_ref, Sender: sender.Ref, SenderAddress: settings.warehouse_ref, ContactSender: contactSender,
      SendersPhone: String(settings.sender_phone).replace(/\D/g, ''), CityRecipient: order.delivery_city_ref,
      Recipient: recipient.Ref, RecipientAddress: order.delivery_address_ref, ContactRecipient: recipientContact,
      RecipientsPhone: String(order.customer_phone).replace(/\D/g, ''), ServiceType: order.delivery_service_type === 'WarehousePostomat' ? 'WarehousePostomat' : 'WarehouseWarehouse',
      ...(order.payment_method === 'CASH_ON_DELIVERY' ? { BackwardDeliveryData: [{ PayerType: 'Recipient', CargoType: 'Money', RedeliveryString: String(Math.max(1, Math.round(Number(order.total_price) / 100))) }] } : {}),
      VolumeGeneral: String((Number(settings.length_cm) * Number(settings.width_cm) * Number(settings.height_cm)) / 1_000_000),
      OptionsSeat: [{ volumetricWidth: String(settings.width_cm), volumetricLength: String(settings.length_cm), volumetricHeight: String(settings.height_cm), weight: String(weightKg) }],
    }))[0]
    if (!document?.IntDocNumber || !document.Ref) throw new Error('Nova Poshta did not return a TTN number')
    const { error: updateError } = await db.from('orders').update({ nova_poshta_ttn: document.IntDocNumber, nova_poshta_document_ref: document.Ref, nova_poshta_ttn_created_at: new Date().toISOString() }).eq('id', order.id).is('nova_poshta_ttn', null)
    if (updateError) throw new Error(updateError.message)
    return json({ ttn: document.IntDocNumber, documentRef: document.Ref, existing: false })
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : 'TTN could not be created' }, 400)
  }
})
