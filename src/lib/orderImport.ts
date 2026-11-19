import { maxOrderVariantQuantity } from './catalogAvailability'
import type { CrmOrderInput } from './crmOrder'
import { optionPrice } from './format'
import { normalizePhone } from './phone'
import { productName } from './productText'
import type { Product } from '../types'

const maxOrderImportBytes = 5 * 1024 * 1024
const maxOrderImportRows = 500

export class OrderImportReadError extends Error {}

export const orderImportRequiredColumns = ['name', 'phone', 'city', 'address', 'quantity'] as const

const headers = {
  order_id: ['order id', 'order number', 'номер замовлення', 'номер заказа', 'id замовлення'],
  name: ['customer name', 'customer', 'recipient', 'ім’я', "ім'я", 'одержувач', 'клієнт', 'имя', 'получатель'],
  phone: ['phone number', 'customer phone', 'телефон', 'номер телефону', 'номер телефона'],
  city: ['delivery city', 'місто', 'город'],
  address: ['delivery address', 'branch', 'адреса', 'відділення', 'адрес', 'отделение'],
  sku: ['article', 'артикул'],
  product: ['product name', 'назва товару', 'товар', 'название товара'],
  size: ['variant', 'розмір', 'размер', 'варіант', 'вариант'],
  quantity: ['qty', 'кількість', 'количество'],
  note: ['comment', 'notes', 'примітка', 'коментар', 'комментарий'],
}
type Column = keyof typeof headers
type SheetRow = { number: number; cells: string[] }
type ImportIssue = { message: string; row?: number; value?: string }
type ImportLine = CrmOrderInput['items'][number] & { name: string; stock: number; allowOutOfStock: boolean; total: number }
export type ImportOrder = Omit<CrmOrderInput, 'items'> & {
  label: string
  row: number
  items: ImportLine[]
}
export type OrderImport = { orders: ImportOrder[]; issues: ImportIssue[] }

const normalize = (value: string) => value.trim().normalize('NFC').toLowerCase().replace(/\s+/g, ' ')
const headerKey = (value: string) => normalize(value).replace(/[_-]/g, ' ')
const columns = Object.keys(headers) as Column[]
const columnKeys = new Map(columns.flatMap(column => [column, ...headers[column]].map(name => [headerKey(name), column] as const)))

export const orderImportTemplate = [
  columns,
  ['101', 'Іван Петренко', '380501234567', 'Київ', 'Відділення № 1', '', 'Keychain', '', '1', ''],
  ['101', '', '', '', '', 'SKU-002', '', '', '2', ''],
]

export async function readOrderImportCsv(csv: string): Promise<string[][]> {
  const { default: Papa } = await import('papaparse')
  const parsed = Papa.parse<string[]>(csv, { delimitersToGuess: [',', ';', '\t'] })
  if (parsed.errors.some(error => error.code !== 'UndetectableDelimiter')) {
    throw new OrderImportReadError('Could not read the spreadsheet.')
  }
  return parsed.data
}

export async function readOrderImportFile(file: File): Promise<unknown[][]> {
  if (file.size > maxOrderImportBytes) throw new OrderImportReadError('Use a spreadsheet up to 5 MB.')
  if (/\.csv$/i.test(file.name)) return readOrderImportCsv(await file.text())
  if (/\.xlsx$/i.test(file.name)) {
    const { readSheet } = await import('read-excel-file/browser')
    return readSheet(file)
  }
  throw new OrderImportReadError('Choose a CSV or XLSX file.')
}

export function prepareOrderImport(sheet: unknown[][], catalog: Product[], language?: string): OrderImport {
  const orders: ImportOrder[] = []
  const issues: ImportIssue[] = []
  const rows: SheetRow[] = sheet.map((cells, index) => ({
    number: index + 1,
    cells: cells.map(cell => String(cell ?? '').trim()),
  })).filter(row => row.cells.some(Boolean))
  const header = rows.shift()
  if (!header || !rows.length) return { orders, issues: [{ message: 'The spreadsheet has no order rows.' }] }
  if (rows.length > maxOrderImportRows) return { orders, issues: [{ message: 'Use up to 500 order rows per import.' }] }

  const fields = new Map<Column, number>()
  header.cells.forEach((value, index) => {
    const column = columnKeys.get(headerKey(value))
    if (!column) return
    if (fields.has(column)) issues.push({ message: 'Duplicate column', value })
    fields.set(column, index)
  })
  for (const column of orderImportRequiredColumns) {
    if (!fields.has(column)) issues.push({ message: 'Missing column', value: column })
  }
  if (!fields.has('sku') && !fields.has('product')) issues.push({ message: 'Missing column', value: 'sku / product' })
  if (issues.length) return { orders, issues }

  const cell = (row: SheetRow, column: Column) => row.cells[fields.get(column) ?? -1] ?? ''
  const groups = new Map<string, SheetRow[]>()
  for (const row of rows) {
    const orderId = cell(row, 'order_id')
    const key = orderId ? `order:${orderId}` : `row:${row.number}`
    const group = groups.get(key) ?? []
    group.push(row)
    groups.set(key, group)
  }

  const variants = catalog.filter(product => product.isActive).flatMap(product =>
    product.productOptions.map(option => ({
      option,
      name: productName(product, language),
      names: [product.name, product.name_uk ?? '', product.name_en ?? ''].map(normalize).filter(Boolean),
    })),
  )
  for (const group of groups.values()) {
    const firstRow = group[0]
    const issueCount = issues.length
    const details = (column: 'name' | 'phone' | 'city' | 'address' | 'note', maxLength: number) => {
      const values = new Set(group.map(row => cell(row, column)).filter(Boolean)
        .map(value => column === 'phone' ? normalizePhone(value) ?? value : value))
      const value = values.values().next().value ?? ''
      if (values.size > 1) issues.push({ row: firstRow.number, message: 'Conflicting values for this order', value: column })
      else if (value.length > maxLength || (!value && column !== 'note')) {
        issues.push({ row: firstRow.number, message: 'Missing or invalid value', value: column })
      }
      return value
    }
    const name = details('name', 200)
    const phone = details('phone', 32)
    const city = details('city', 200)
    const address = details('address', 500)
    const note = details('note', 2000)
    if (phone && !normalizePhone(phone)) issues.push({ row: firstRow.number, message: 'Use a valid phone number with country code.' })

    const items = new Map<string, ImportLine>()
    for (const row of group) {
      const sku = cell(row, 'sku')
      const product = normalize(cell(row, 'product'))
      const size = normalize(cell(row, 'size'))
      const matches = variants.filter(({ option, names }) =>
        (sku ? normalize(option.sku ?? '') === normalize(sku) : Boolean(product))
        && (!product || names.includes(product))
        && (!size || normalize(option.name) === size))
      if (matches.length !== 1) {
        issues.push({
          row: row.number,
          message: matches.length ? 'Several variants match. Specify a unique SKU or product and size.' : 'No published variant matches this row.',
        })
        continue
      }
      const { option, name } = matches[0]
      const units = cell(row, 'quantity')
      const quantity = Number(units) + (items.get(option.id)?.quantity ?? 0)
      if (!/^\d+$/.test(units) || Number(units) < 1 || quantity > maxOrderVariantQuantity) {
        issues.push({ row: row.number, message: 'Use 1–20 units per variant in each order.' })
        continue
      }
      items.set(option.id, {
        variantId: option.id, name: `${name} · ${option.name}`, stock: option.quantity, quantity,
        allowOutOfStock: option.allowOutOfStock === true,
        total: Math.round(optionPrice(option) * 100) * quantity,
      })
    }
    if (issues.length !== issueCount) continue
    orders.push({
      requestId: crypto.randomUUID(), label: cell(firstRow, 'order_id'), row: firstRow.number,
      customer: { name, phone }, delivery: { city, address }, note, items: [...items.values()],
      total: [...items.values()].reduce((sum, item) => sum + item.total, 0),
    })
  }

  const remainingStock = new Map<string, number>()
  for (const order of orders) {
    for (const item of order.items) {
      const stock = remainingStock.get(item.variantId) ?? item.stock
      if (stock === 0 && item.allowOutOfStock) continue
      if (item.quantity > stock) {
        issues.push({ row: order.row, message: 'Insufficient stock for the batch', value: `${item.name} · ${item.quantity} / ${stock}` })
      } else {
        remainingStock.set(item.variantId, stock - item.quantity)
      }
    }
  }
  return { orders, issues }
}
