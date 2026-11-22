import { createClient } from 'npm:@supabase/supabase-js@2'
import { invalidTtnRecipientName, parseTtnRecipientName } from '../_shared/ttn-recipient.ts'
import { NovaPoshtaRateLimit, novaPoshtaRateLimit } from '../_shared/nova-poshta-rate-limit.ts'

type NovaData = Record<string, unknown>
class NovaPostRejection extends Error {}

const cors = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Access-Control-Expose-Headers': 'Retry-After' }
const json = (body: unknown, status = 200, retryAfter?: number) => new Response(JSON.stringify(body), {
  status, headers: retryAfter === undefined ? cors : { ...cors, 'Retry-After': String(retryAfter) },
})
const isDirectoryRef = (value: unknown): value is string =>
  typeof value === 'string' && /^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(value)

function dateForNovaPost(date = new Date()) {
  return new Intl.DateTimeFormat('uk-UA', { timeZone: 'Europe/Kyiv', day: '2-digit', month: '2-digit', year: 'numeric' }).format(date)
}

async function novaPost(apiKey: string, modelName: string, calledMethod: string, methodProperties: NovaData) {
  const signal = AbortSignal.timeout(8000)
  try {
    const response = await fetch('https://api.novaposhta.ua/v2.0/json/', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ apiKey, modelName, calledMethod, methodProperties }), signal,
    })
    const result = await response.json().catch(() => null) as { success?: boolean; data?: NovaData[]; errors?: string[]; warnings?: string[]; message?: string } | null
    const message = (Array.isArray(result?.errors) && result.errors.join(', ')) ||
      (Array.isArray(result?.warnings) && result.warnings.join(', ')) || result?.message || ''
    const rejected = response.ok && result?.success === false
    const limit = novaPoshtaRateLimit(response, message, rejected)
    if (limit) throw limit
    if (rejected) throw new NovaPostRejection(message || 'Nova Poshta request failed')
    if (!response.ok || !result?.success) throw new Error(message || 'Nova Poshta request failed')
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

type SenderMatch = { senderRef: unknown; contactRef: unknown; name: string }
const senderLookups = new Map<string, { result: Promise<SenderMatch>; expiresAt: number }>()

function resolveSender(apiKey: string, cityRef: string, name: string, phone: string) {
  const key = JSON.stringify([apiKey, cityRef, name, phone])
  const current = senderLookups.get(key)
  if (current && current.expiresAt > Date.now()) return current.result
  senderLookups.delete(key)
  const result = findSender(apiKey, cityRef, name, phone).catch(error => {
    if (senderLookups.get(key)?.result === result) senderLookups.delete(key)
    throw error
  })
  senderLookups.set(key, { result, expiresAt: Date.now() + 5 * 60_000 })
  const oldestKey = senderLookups.keys().next().value
  if (senderLookups.size > 32 && oldestKey !== undefined) senderLookups.delete(oldestKey)
  return result
}

async function findSender(apiKey: string, cityRef: string, name: string, phone: string): Promise<SenderMatch> {
  // The Sender directory can omit valid counterparties when FindByString is sent.
  const senders = (await novaPost(apiKey, 'Counterparty', 'getCounterparties', {
    CounterpartyProperty: 'Sender', City: cityRef, Page: '1', Limit: '20',
  })).filter(sender => typeof sender.Ref === 'string' && sender.Ref)
  if (!senders.length) throw new Error('The Nova Poshta API key has no sender for the configured dispatch city.')

  const normalizeName = (value: unknown) => String(value ?? '').trim().toLowerCase().replace(/\s+/g, ' ')
  const nameMatches = senders.filter(sender => normalizeName(sender.Description) === normalizeName(name))
  const candidates = nameMatches.length ? nameMatches : senders
  const readContacts = async (sender: NovaData) => {
    const contacts = await novaPost(apiKey, 'Counterparty', 'getCounterpartyContactPersons', { Ref: sender.Ref, Page: '1' })
    return contacts.filter(contact => typeof contact.Ref === 'string' && contact.Ref &&
      [contact.Phones, contact.Phone].some(value =>
        String(value ?? '').split(/[,;/]/).some(number => senderPhone(number) === phone),
      )).map(contact => ({ senderRef: sender.Ref, contactRef: contact.Ref, name: normalizeName(contact.Description) }))
  }
  const matches: SenderMatch[] = []
  for (let start = 0; start < candidates.length; start += 3) {
    matches.push(...(await Promise.all(candidates.slice(start, start + 3).map(readContacts))).flat())
  }
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
  let attemptId: string | null = null
  let documentAttempted = false
  let documentRejected = false
  try {
    const { orderId, description, internalOrderNumber, weightGrams, declaredValueMinor, expectedCodMinor, recipientName, dispatchLocation, recipientLocation, recovery } = (preview
      ? { orderId: new URL(request.url).searchParams.get('orderId') }
      : await request.json()) as {
      orderId?: string | null
      description?: unknown
      internalOrderNumber?: unknown
      weightGrams?: unknown
      expectedCodMinor?: unknown
      declaredValueMinor?: unknown
      recipientName?: unknown
      dispatchLocation?: { cityRef?: unknown; warehouseRef?: unknown } | null
      recipientLocation?: { cityRef?: unknown; cityName?: unknown; warehouseRef?: unknown; warehouseName?: unknown } | null
      recovery?: { action?: unknown; attemptId?: unknown; ttn?: unknown }
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
    if (recovery !== undefined) {
      const { action, attemptId: requestedAttempt, ttn: trackingNumber } = recovery ?? {}
      if ((action !== 'attach' && action !== 'not_created') ||
        ((requestedAttempt !== undefined || action === 'not_created') && !isDirectoryRef(requestedAttempt))) {
        return json({ error: 'Invalid TTN recovery request.' }, 400)
      }
      if (action === 'attach' && order.nova_poshta_ttn) {
        if (order.nova_poshta_ttn === trackingNumber) {
          return json({ ttn: order.nova_poshta_ttn, documentRef: order.nova_poshta_document_ref, existing: true })
        }
        return json({ error: 'This order already has a TTN.' }, 409)
      }
      let pending: { client_reference: string | null; created_at: string } | null = null
      if (requestedAttempt !== undefined) {
        const { data, error: pendingError } = await db.from('order_ttn_reservations')
          .select('client_reference,needs_review,created_at').eq('order_id', orderId).eq('attempt_id', requestedAttempt).maybeSingle()
        if (pendingError) throw new Error(pendingError.message)
        if (!data) return json({ error: 'This TTN attempt is no longer current.' }, 409)
        if (!data.needs_review && Date.now() - Date.parse(data.created_at) < 8 * 60_000) {
          return json({ error: 'TTN creation is still in progress.' }, 409)
        }
        pending = data
      }
      let ttn: string | null = null
      let documentRef: string | null = null
      if (action === 'attach') {
        if (typeof trackingNumber !== 'string' || !/^[0-9]{14}$/.test(trackingNumber)) {
          return json({ error: 'Enter a valid 14-digit Nova Poshta tracking number.' }, 400)
        }
        const apiKey = Deno.env.get('NOVA_POSHTA_API_KEY')?.trim()
        if (!apiKey) throw new Error('NOVA_POSHTA_API_KEY is not configured')
        const search: NovaData = { IntDocNumber: trackingNumber, Page: '1' }
        if (pending) {
          const attemptedAt = Date.parse(pending.created_at)
          search.GetFullList = '1'
          search.DateTimeFrom = dateForNovaPost(new Date(attemptedAt - 86_400_000))
          search.DateTimeTo = dateForNovaPost(new Date(attemptedAt + 86_400_000))
        }
        const documents = await novaPost(apiKey, 'InternetDocument', 'getDocumentList', search)
        const document = documents.find(row => String(row.IntDocNumber) === trackingNumber)
        if (typeof document?.Ref !== 'string' || !document.Ref) {
          return json({ error: 'Nova Poshta did not find this TTN in the connected account.' }, 404)
        }
        if (pending?.client_reference && document.InfoRegClientBarcodes &&
          String(document.InfoRegClientBarcodes) !== pending.client_reference) {
          return json({ error: 'This TTN belongs to a different order number.' }, 409)
        }
        ttn = trackingNumber
        documentRef = document.Ref
      }
      const { error } = await db.rpc('settle_order_ttn_as_staff', {
        p_order_id: orderId, p_attempt_id: requestedAttempt ?? null, p_actor: userData.user.id,
        p_outcome: action === 'attach' ? 'attached' : 'not_created', p_ttn: ttn, p_document_ref: documentRef,
      })
      if (error) return json({ error: error.message }, 409)
      return json({ ttn, documentRef })
    }
    if (String(order.status).startsWith('CANCELLED')) throw new Error('A TTN cannot be created for a cancelled order')
    if (!preview && order.nova_poshta_ttn) return json({ ttn: order.nova_poshta_ttn, documentRef: order.nova_poshta_document_ref, existing: true })
    if (!['PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED'].includes(order.status)) {
      throw new Error('Move the order to preparing for shipment first')
    }
    if (order.currency !== 'UAH') throw new Error('Nova Poshta TTN requires an order in UAH')
    if (!preview) {
      const { data, error } = await db.rpc('begin_order_ttn_attempt', { p_order_id: orderId })
      if (error) throw new Error('TTN creation is already in progress or the order was merged. Refresh the page.')
      reservedOrder = orderId
      attemptId = data as string
    }
    const { data: shippingRows, error: shippingError } = await db.rpc('merged_order_shipping', { p_order_id: orderId })
    if (shippingError) throw new Error(shippingError.message)
    if (!shippingRows?.[0]) throw new Error('Could not calculate the merged order.')
    const shipping = shippingRows[0] as { total_minor: number; cod_minor: number; weight_grams: number | null }
    const orderTotalMinor = Number(shipping.total_minor)
    const { data: settings, error: settingsError } = await db.from('delivery_settings').select('*').eq('store_id', order.store_id).maybeSingle()
    if (preview) {
      if (order.nova_poshta_ttn) throw new Error('This order already has a TTN.')
      if (settingsError) throw new Error('Could not load delivery settings.')
      return json({
        codMinor: Number(shipping.cod_minor),
        weightGrams: shipping.weight_grams,
        declaredValueMinor: Math.max(100, orderTotalMinor),
        dispatchLocation: {
          cityRef: settings?.city_ref ?? '',
          cityName: settings?.city_name ?? '',
          warehouseRef: settings?.warehouse_ref ?? '',
          warehouseName: settings?.warehouse_name ?? '',
        },
        recipientLocation: {
          cityRef: order.delivery_city_ref ?? '',
          cityName: order.delivery_city ?? '',
          warehouseRef: order.delivery_address_ref ?? '',
          warehouseName: order.delivery_address ?? '',
        },
      })
    }
    if (expectedCodMinor !== undefined && expectedCodMinor !== Number(shipping.cod_minor)) throw new Error('COD amount changed. Reopen the shipment.')
    let destination = {
      delivery_city_ref: order.delivery_city_ref,
      delivery_city: order.delivery_city,
      delivery_address_ref: order.delivery_address_ref,
      delivery_address: order.delivery_address,
      delivery_service_type: order.delivery_service_type,
    }
    if (recipientLocation !== undefined) {
      const cityName = typeof recipientLocation?.cityName === 'string' ? recipientLocation.cityName.trim() : ''
      const branchName = typeof recipientLocation?.warehouseName === 'string' ? recipientLocation.warehouseName.trim() : ''
      if (!isDirectoryRef(recipientLocation?.cityRef) || !isDirectoryRef(recipientLocation?.warehouseRef) ||
        !cityName || cityName.length > 200 || !branchName || branchName.length > 500) {
        throw new Error('Choose a city and Nova Poshta branch')
      }
      if (recipientLocation.cityRef !== destination.delivery_city_ref || recipientLocation.warehouseRef !== destination.delivery_address_ref) {
        destination = {
          delivery_city_ref: recipientLocation.cityRef, delivery_city: cityName,
          delivery_address_ref: recipientLocation.warehouseRef, delivery_address: branchName,
          delivery_service_type: /поштомат|postomat/i.test(branchName) ? 'WarehousePostomat' : 'WarehouseWarehouse',
        }
      }
    }
    if (!destination.delivery_city_ref || !destination.delivery_address_ref) {
      throw new Error('Choose a city and Nova Poshta branch')
    }
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

    if (settingsError || !settings) throw new Error('Configure Nova Poshta sender settings first')
    let dispatchCityRef = settings.city_ref
    let dispatchWarehouseRef = settings.warehouse_ref
    if (dispatchLocation !== undefined) {
      if (!isDirectoryRef(dispatchLocation?.cityRef) || !isDirectoryRef(dispatchLocation?.warehouseRef)) {
        throw new Error('Choose a dispatch city and branch from the Nova Poshta directory.')
      }
      dispatchCityRef = dispatchLocation.cityRef
      dispatchWarehouseRef = dispatchLocation.warehouseRef
    }
    if (!settings.sender_name || !settings.sender_phone || !dispatchCityRef || !dispatchWarehouseRef) throw new Error('Fill in sender name, phone, city and dispatch branch in Nova Poshta settings')
    const orderWeight = weightGrams === undefined ? shipping.weight_grams : weightGrams
    // The previous CRM sends only orderId. Keep its fallback until that UI is replaced.
    const legacyRequest = description === undefined && internalOrderNumber === undefined && weightGrams === undefined && declaredValueMinor === undefined
    const parcelWeightGrams = legacyRequest && orderWeight === null
      ? Math.max(100, Number(settings.default_weight_grams))
      : orderWeight
    if (typeof parcelWeightGrams !== 'number' || !Number.isSafeInteger(parcelWeightGrams) || parcelWeightGrams <= 0) {
      throw new Error('Enter a positive weight in whole grams.')
    }

    const apiKey = Deno.env.get('NOVA_POSHTA_API_KEY')?.trim()
    if (!apiKey) throw new Error('NOVA_POSHTA_API_KEY is not configured')

    const dispatchPhone = senderPhone(settings.sender_phone)
    if (!dispatchPhone) throw new Error('Enter a valid sender phone in delivery settings.')
    const sender = await resolveSender(apiKey, dispatchCityRef, settings.sender_name, dispatchPhone)

    const recipients = await novaPost(apiKey, 'Counterparty', 'save', {
      FirstName: person.firstName, MiddleName: person.middleName, LastName: person.lastName,
      Phone: String(order.customer_phone).replace(/\D/g, ''), Email: String(order.customer_email),
      CounterpartyType: 'PrivatePerson', CounterpartyProperty: 'Recipient', CityRef: destination.delivery_city_ref,
    })
    const recipient = recipients[0]
    const recipientContact = (recipient?.ContactPerson as { data?: NovaData[] } | undefined)?.data?.[0]?.Ref
    if (!recipient?.Ref || !recipientContact) throw new Error('Nova Poshta could not create the recipient')

    const weightKg = String(parcelWeightGrams / 1000)
    const codMinor = Number(shipping.cod_minor)
    if (!Number.isSafeInteger(codMinor) || codMinor < 0) throw new Error('Invalid cash on delivery amount')
    const codAmount = codMinor % 100 === 0 ? String(codMinor / 100) : (codMinor / 100).toFixed(2)
    const { error: prepareError } = await db.rpc('prepare_order_ttn_request', {
      p_order_id: orderId, p_attempt_id: attemptId, p_address: destination, p_client_reference: orderNumber || null,
    })
    if (prepareError) throw new Error(prepareError.message)
    documentAttempted = true
    const document = (await novaPost(apiKey, 'InternetDocument', 'save', {
      PayerType: settings.delivery_payer === 'SENDER' ? 'Sender' : 'Recipient', PaymentMethod: 'Cash',
      DateTime: dateForNovaPost(), CargoType: 'Parcel', Weight: weightKg, SeatsAmount: '1',
      Description: parcelDescription.trim(), Cost: String(declaredValueUah),
      ...(orderNumber ? { InfoRegClientBarcodes: orderNumber } : {}),
      CitySender: dispatchCityRef, Sender: sender.senderRef, SenderAddress: dispatchWarehouseRef, ContactSender: sender.contactRef,
      SendersPhone: dispatchPhone, CityRecipient: destination.delivery_city_ref,
      Recipient: recipient.Ref, RecipientAddress: destination.delivery_address_ref, ContactRecipient: recipientContact,
      RecipientsPhone: String(order.customer_phone).replace(/\D/g, ''), ServiceType: destination.delivery_service_type === 'WarehousePostomat' ? 'WarehousePostomat' : 'WarehouseWarehouse',
      ...(codMinor > 0 ? { BackwardDeliveryData: [{ PayerType: 'Recipient', CargoType: 'Money', RedeliveryString: codAmount }] } : {}),
      VolumeGeneral: String((Number(settings.length_cm) * Number(settings.width_cm) * Number(settings.height_cm)) / 1_000_000),
      OptionsSeat: [{ volumetricWidth: String(settings.width_cm), volumetricLength: String(settings.length_cm), volumetricHeight: String(settings.height_cm), weight: weightKg }],
    }))[0]
    if (!document?.IntDocNumber || !document.Ref) throw new Error('Nova Poshta did not return a TTN number')
    const { error: updateError } = await db.rpc('settle_order_ttn_as_staff', {
      p_order_id: orderId, p_attempt_id: attemptId, p_outcome: 'created', p_actor: userData.user.id,
      p_ttn: String(document.IntDocNumber), p_document_ref: document.Ref,
    })
    if (updateError) throw new Error(updateError.message)
    attemptId = null
    return json({ ttn: document.IntDocNumber, documentRef: document.Ref, existing: false })
  } catch (error) {
    documentRejected = error instanceof NovaPostRejection || (error instanceof NovaPoshtaRateLimit && error.rejected)
    if (error instanceof NovaPoshtaRateLimit && (!documentAttempted || documentRejected)) {
      return json({ error: error.message }, 429, error.retryAfter)
    }
    const message = error instanceof Error ? error.message : 'TTN could not be created'
    return json({ error: documentAttempted && !documentRejected ? 'Check the Nova Poshta account and resolve this TTN in the order card.' : message }, 400)
  } finally {
    if (reservedOrder && attemptId) await db.rpc('finish_order_ttn_attempt', {
      p_order_id: reservedOrder, p_attempt_id: attemptId,
      p_outcome: documentAttempted && !documentRejected ? 'uncertain' : 'rejected',
    })
  }
})
