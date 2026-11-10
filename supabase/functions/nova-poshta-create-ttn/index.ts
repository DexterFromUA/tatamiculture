import { createClient } from 'npm:@supabase/supabase-js@2'
import { invalidTtnRecipientName, parseTtnRecipientName } from '../_shared/ttn-recipient.ts'

type NovaData = Record<string, unknown>
class NovaPostRejection extends Error {}

const cors = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' }
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors })

function dateForNovaPost() {
  const now = new Date()
  return `${String(now.getDate()).padStart(2, '0')}.${String(now.getMonth() + 1).padStart(2, '0')}.${now.getFullYear()}`
}

async function novaPost(apiKey: string, modelName: string, calledMethod: string, methodProperties: NovaData) {
  const signal = AbortSignal.timeout(8000)
  try {
    const response = await fetch('https://api.novaposhta.ua/v2.0/json/', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ apiKey, modelName, calledMethod, methodProperties }), signal,
    })
    const result = await response.json() as { success?: boolean; data?: NovaData[]; errors?: string[]; warnings?: string[] }
    if (response.ok && result.success === false) throw new NovaPostRejection(result.errors?.join(', ') || result.warnings?.join(', ') || 'Nova Poshta request failed')
    if (!response.ok || !result.success) throw new Error(result.errors?.join(', ') || result.warnings?.join(', ') || 'Nova Poshta request failed')
    return result.data ?? []
  } catch (error) {
    if (signal.aborted) throw new Error('Nova Poshta did not respond in time.', { cause: error })
    throw error
  }
}

function senderPhone(value: unknown) {
  const digits = String(value ?? '').replace(/\D/g, '')
  return /^0\d{9}$/.test(digits) ? `38${digits}` : digits
}

async function resolveSender(apiKey: string, cityRef: string, name: string, phone: string) {
  // The Sender directory can omit valid counterparties when FindByString is sent.
  const senders = (await novaPost(apiKey, 'Counterparty', 'getCounterparties', {
    CounterpartyProperty: 'Sender', City: cityRef, Page: '1', Limit: '20',
  })).filter(sender => typeof sender.Ref === 'string' && sender.Ref)
  if (!senders.length) throw new Error('The Nova Poshta API key has no sender for the configured dispatch city.')

  const normalizeName = (value: unknown) => String(value ?? '').trim().toLowerCase().replace(/\s+/g, ' ')
  const nameMatches = senders.filter(sender => normalizeName(sender.Description) === normalizeName(name))
  const candidates = nameMatches.length ? nameMatches : senders
  const matches = (await Promise.all(candidates.map(async sender => {
    const contacts = await novaPost(apiKey, 'Counterparty', 'getCounterpartyContactPersons', { Ref: sender.Ref, Page: '1' })
    return contacts.filter(contact => typeof contact.Ref === 'string' && contact.Ref &&
      [contact.Phones, contact.Phone].some(value =>
        String(value ?? '').split(/[,;/]/).some(number => senderPhone(number) === phone),
      )).map(contact => ({ senderRef: sender.Ref, contactRef: contact.Ref, name: normalizeName(contact.Description) }))
  }))).flat()
  if (matches.length === 1) return matches[0]
  const namedContacts = matches.filter(contact => contact.name === normalizeName(name))
  if (namedContacts.length === 1) return namedContacts[0]
  if (matches.length > 1) throw new Error('Multiple Nova Poshta sender contacts use this phone. Check the sender name or company in delivery settings.')
  throw new Error('No Nova Poshta sender contact matches the phone in delivery settings.')
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const preview = request.method === 'GET'
  if (!preview && request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return json({ error: 'Supabase is not configured' }, 503)

  const db = createClient(supabaseUrl, serviceRoleKey)
  let reservedOrder: string | null = null
  let documentAttempted = false
  let documentSaved = false
  let documentRejected = false
  try {
    const { orderId, description, internalOrderNumber, weightGrams, declaredValueMinor, recipientName } = (preview
      ? { orderId: new URL(request.url).searchParams.get('orderId') }
      : await request.json()) as {
      orderId?: string | null
      description?: unknown
      internalOrderNumber?: unknown
      weightGrams?: unknown
      declaredValueMinor?: unknown
      recipientName?: unknown
    }
    if (!orderId) throw new Error('Order is required')
    const authorization = request.headers.get('Authorization') ?? `Bearer ${anonKey}`
    const authClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } } })
    const { data: userData, error: userError } = await authClient.auth.getUser()
    if (userError || !userData.user) return json({ error: 'Sign in as a store manager first' }, 401)
    const { data: order, error: orderError } = await db.from('orders').select('*').eq('id', orderId).maybeSingle()
    if (orderError || !order) return json({ error: 'Order was not found' }, 404)
    const { data: membership } = await db.from('store_members').select('role').eq('store_id', order.store_id).eq('user_id', userData.user.id).maybeSingle()
    if (!membership) return json({ error: 'You do not have access to this order' }, 403)
    if (String(order.status).startsWith('CANCELLED')) throw new Error('A TTN cannot be created for a cancelled order')
    if (!preview && order.nova_poshta_ttn) return json({ ttn: order.nova_poshta_ttn, documentRef: order.nova_poshta_document_ref, existing: true })
    if (order.currency !== 'UAH') throw new Error('Nova Poshta TTN requires an order in UAH')
    if (!preview) {
      const { error } = await db.rpc('reserve_order_ttn', { p_order_id: orderId })
      if (error) throw new Error('TTN creation is already in progress or the order was merged. Refresh the page.')
      reservedOrder = orderId
    }
    const { data: shippingRows, error: shippingError } = await db.rpc('merged_order_shipping', { p_order_id: orderId })
    if (shippingError || !shippingRows?.[0]) throw new Error('Could not calculate the merged order.')
    const shipping = shippingRows[0] as { order_ids: string[]; total_minor: number; cod_minor: number; weight_grams: number | null }
    const orderTotalMinor = Number(shipping.total_minor)
    if (preview) {
      if (order.nova_poshta_ttn) throw new Error('This order already has a TTN.')
      return json({ weightGrams: shipping.weight_grams, declaredValueMinor: Math.max(100, orderTotalMinor) })
    }
    if (!order.delivery_city_ref || !order.delivery_address_ref) throw new Error('This order lacks Nova Poshta branch references. Create a new order after enabling delivery, or set its destination again.')
    const person = parseTtnRecipientName(recipientName === undefined ? order.customer_name : recipientName)
    if (!person) throw new Error(invalidTtnRecipientName)

    const parcelDescription = description === undefined ? `tatami.culture order ${order.receipt_code}` : description
    if (typeof parcelDescription !== 'string' || !parcelDescription.trim()) throw new Error('Enter a parcel description.')
    if (internalOrderNumber !== undefined && typeof internalOrderNumber !== 'string') throw new Error('Enter a valid internal order number.')
    const orderNumber = internalOrderNumber?.trim()
    // Older CRM versions omit the field and keep the existing whole-UAH default.
    const declaredMinor = declaredValueMinor === undefined
      ? Math.max(1, Math.round(orderTotalMinor / 100)) * 100
      : declaredValueMinor
    if (typeof declaredMinor !== 'number' || !Number.isSafeInteger(declaredMinor) || declaredMinor < 100) {
      throw new Error('Enter a declared value of at least 1 UAH.')
    }
    const declaredValueUah = declaredMinor / 100

    const { data: settings, error: settingsError } = await db.from('delivery_settings').select('*').eq('store_id', order.store_id).maybeSingle()
    if (settingsError || !settings) throw new Error('Configure Nova Poshta sender settings first')
    if (!settings.sender_name || !settings.sender_phone || !settings.city_ref || !settings.warehouse_ref) throw new Error('Fill in sender name, phone, city and dispatch branch in Nova Poshta settings')
    const orderWeight = weightGrams === undefined ? shipping.weight_grams : weightGrams
    // The previous CRM sends only orderId. Keep its fallback until that UI is replaced.
    const legacyRequest = description === undefined && internalOrderNumber === undefined && weightGrams === undefined && declaredValueMinor === undefined
    const parcelWeightGrams = legacyRequest && orderWeight === null
      ? Math.max(100, Number(settings.default_weight_grams))
      : orderWeight
    if (typeof parcelWeightGrams !== 'number' || !Number.isSafeInteger(parcelWeightGrams) || parcelWeightGrams <= 0) {
      throw new Error('Enter a positive weight in whole grams.')
    }

    const apiKey = settings.nova_post_test_mode ? Deno.env.get('NOVA_POSHTA_TEST_API_KEY')?.trim() : Deno.env.get('NOVA_POSHTA_API_KEY')?.trim()
    if (!apiKey) throw new Error(settings.nova_post_test_mode ? 'NOVA_POSHTA_TEST_API_KEY is not configured' : 'NOVA_POSHTA_API_KEY is not configured')

    const dispatchPhone = senderPhone(settings.sender_phone)
    if (!dispatchPhone) throw new Error('Enter a valid sender phone in delivery settings.')
    const sender = await resolveSender(apiKey, settings.city_ref, settings.sender_name, dispatchPhone)

    const recipients = await novaPost(apiKey, 'Counterparty', 'save', {
      FirstName: person.firstName, MiddleName: person.middleName, LastName: person.lastName,
      Phone: String(order.customer_phone).replace(/\D/g, ''), Email: String(order.customer_email),
      CounterpartyType: 'PrivatePerson', CounterpartyProperty: 'Recipient', CityRef: order.delivery_city_ref,
    })
    const recipient = recipients[0]
    const recipientContact = (recipient?.ContactPerson as { data?: NovaData[] } | undefined)?.data?.[0]?.Ref
    if (!recipient?.Ref || !recipientContact) throw new Error('Nova Poshta could not create the recipient')

    const weightKg = String(parcelWeightGrams / 1000)
    documentAttempted = true
    const document = (await novaPost(apiKey, 'InternetDocument', 'save', {
      PayerType: settings.delivery_payer === 'SENDER' ? 'Sender' : 'Recipient', PaymentMethod: 'Cash',
      DateTime: dateForNovaPost(), CargoType: 'Parcel', Weight: weightKg, SeatsAmount: '1',
      Description: parcelDescription.trim(), Cost: String(declaredValueUah),
      ...(orderNumber ? { InfoRegClientBarcodes: orderNumber } : {}),
      CitySender: settings.city_ref, Sender: sender.senderRef, SenderAddress: settings.warehouse_ref, ContactSender: sender.contactRef,
      SendersPhone: dispatchPhone, CityRecipient: order.delivery_city_ref,
      Recipient: recipient.Ref, RecipientAddress: order.delivery_address_ref, ContactRecipient: recipientContact,
      RecipientsPhone: String(order.customer_phone).replace(/\D/g, ''), ServiceType: order.delivery_service_type === 'WarehousePostomat' ? 'WarehousePostomat' : 'WarehouseWarehouse',
      ...(Number(shipping.cod_minor) > 0 ? { BackwardDeliveryData: [{ PayerType: 'Recipient', CargoType: 'Money', RedeliveryString: String(Math.max(1, Math.round(Number(shipping.cod_minor) / 100))) }] } : {}),
      VolumeGeneral: String((Number(settings.length_cm) * Number(settings.width_cm) * Number(settings.height_cm)) / 1_000_000),
      OptionsSeat: [{ volumetricWidth: String(settings.width_cm), volumetricLength: String(settings.length_cm), volumetricHeight: String(settings.height_cm), weight: weightKg }],
    }))[0]
    if (!document?.IntDocNumber || !document.Ref) throw new Error('Nova Poshta did not return a TTN number')
    const { error: updateError } = await db.from('orders').update({ nova_poshta_ttn: document.IntDocNumber, nova_poshta_document_ref: document.Ref, nova_poshta_ttn_created_at: new Date().toISOString() }).in('id', shipping.order_ids).is('nova_poshta_ttn', null)
    if (updateError) throw new Error(updateError.message)
    documentSaved = true
    return json({ ttn: document.IntDocNumber, documentRef: document.Ref, existing: false })
  } catch (error) {
    documentRejected = error instanceof NovaPostRejection
    const message = error instanceof Error ? error.message : 'TTN could not be created'
    return json({ error: documentAttempted && !documentSaved && !documentRejected ? `${message} Check the Nova Poshta account before retrying.` : message }, 400)
  } finally {
    if (reservedOrder && (!documentAttempted || documentSaved || documentRejected)) await db.rpc('release_order_ttn', { p_order_id: reservedOrder })
  }
})
