import { useCallback, useEffect, useMemo, useState } from 'react'
import { formatDate, formatPrice } from '../lib/format'
import { supabaseRequest } from '../lib/supabase'
import type { OrderStatus, PaymentStatus } from '../types'

export type CustomerOrder = {
  id: string
  user_id: string | null
  receipt_code: string
  customer_name: string
  customer_email: string
  customer_phone: string
  total_price: number
  currency: string
  status: OrderStatus
  payment_status: PaymentStatus
  created_at: string
}

type CustomerTag = { id: string; name: string; color: string }
type CustomerNote = { id: string; body: string; created_at: string }

type Props = {
  order: CustomerOrder
  storeId: string
  token: string
  managerId: string
  onClose: () => void
}

export function CustomerPanel({ order, storeId, token, managerId, onClose }: Props) {
  const [history, setHistory] = useState<CustomerOrder[]>([])
  const [tags, setTags] = useState<CustomerTag[]>([])
  const [assignedTagIds, setAssignedTagIds] = useState<string[]>([])
  const [notes, setNotes] = useState<CustomerNote[]>([])
  const [note, setNote] = useState('')
  const [newTag, setNewTag] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!order.user_id) return
    setLoading(true)
    try {
      const [nextHistory, nextTags, assignments, nextNotes] = await Promise.all([
        supabaseRequest<CustomerOrder[]>(`/rest/v1/orders?store_id=eq.${encodeURIComponent(storeId)}&user_id=eq.${encodeURIComponent(order.user_id)}&select=id,user_id,receipt_code,customer_name,customer_email,customer_phone,total_price,currency,status,payment_status,created_at&order=created_at.desc`, { token }),
        supabaseRequest<CustomerTag[]>(`/rest/v1/customer_tags?store_id=eq.${encodeURIComponent(storeId)}&select=id,name,color&order=name.asc`, { token }),
        supabaseRequest<Array<{ tag_id: string }>>(`/rest/v1/customer_tag_assignments?customer_id=eq.${encodeURIComponent(order.user_id)}&select=tag_id`, { token }),
        supabaseRequest<CustomerNote[]>(`/rest/v1/customer_notes?store_id=eq.${encodeURIComponent(storeId)}&customer_id=eq.${encodeURIComponent(order.user_id)}&select=id,body,created_at&order=created_at.desc`, { token }),
      ])
      setHistory(nextHistory)
      setTags(nextTags)
      setAssignedTagIds(assignments.map((assignment) => assignment.tag_id))
      setNotes(nextNotes)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not load customer')
    } finally {
      setLoading(false)
    }
  }, [order.user_id, storeId, token])

  useEffect(() => {
    const timer = window.setTimeout(() => { void load() }, 0)
    return () => window.clearTimeout(timer)
  }, [load])

  const totalSpent = useMemo(() => history.filter((item) => !item.status.startsWith('CANCELLED')).reduce((sum, item) => sum + Number(item.total_price), 0) / 100, [history])
  const assignedTags = tags.filter((tag) => assignedTagIds.includes(tag.id))
  const availableTags = tags.filter((tag) => !assignedTagIds.includes(tag.id))

  const addNote = async () => {
    if (!order.user_id || !note.trim()) return
    setSaving(true)
    try {
      await supabaseRequest('/rest/v1/customer_notes', {
        method: 'POST', token,
        body: JSON.stringify({ store_id: storeId, customer_id: order.user_id, author_id: managerId, body: note.trim() }),
      })
      setNote('')
      await load()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save note')
    } finally { setSaving(false) }
  }

  const assignTag = async (tagId: string) => {
    if (!order.user_id) return
    setSaving(true)
    try {
      await supabaseRequest('/rest/v1/customer_tag_assignments', { method: 'POST', token, body: JSON.stringify({ tag_id: tagId, customer_id: order.user_id }) })
      setAssignedTagIds((current) => [...current, tagId])
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not assign tag')
    } finally { setSaving(false) }
  }

  const removeTag = async (tagId: string) => {
    if (!order.user_id) return
    setSaving(true)
    try {
      await supabaseRequest(`/rest/v1/customer_tag_assignments?tag_id=eq.${encodeURIComponent(tagId)}&customer_id=eq.${encodeURIComponent(order.user_id)}`, { method: 'DELETE', token })
      setAssignedTagIds((current) => current.filter((id) => id !== tagId))
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not remove tag')
    } finally { setSaving(false) }
  }

  const createTag = async () => {
    if (!newTag.trim() || !order.user_id) return
    setSaving(true)
    try {
      const created = await supabaseRequest<CustomerTag[]>('/rest/v1/customer_tags', {
        method: 'POST', token, headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ store_id: storeId, name: newTag.trim(), color: '#203f36' }),
      })
      const tag = created[0]
      if (!tag) throw new Error('Could not create tag')
      setTags((current) => [...current, tag])
      setNewTag('')
      await assignTag(tag.id)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not create tag')
    } finally { setSaving(false) }
  }

  return (
    <aside className="customer-panel" aria-label="Customer card">
      <div className="product-editor__head"><div><p className="muted">Customer</p><h2>{order.customer_name}</h2></div><button type="button" className="text-btn" onClick={onClose}>Close</button></div>
      <p>{order.customer_email}<br />{order.customer_phone}</p>
      {error ? <p className="error">{error}</p> : null}
      {loading ? <p className="muted">Loading customer…</p> : <>
        <div className="customer-panel__stats"><div><span>Orders</span><strong>{history.length}</strong></div><div><span>Spent</span><strong>{formatPrice(totalSpent, order.currency)}</strong></div></div>
        <section className="customer-section"><h3>Tags</h3><div className="tag-list">{assignedTags.map((tag) => <button type="button" key={tag.id} className="tag" style={{ borderColor: tag.color }} disabled={saving} onClick={() => void removeTag(tag.id)}>{tag.name} ×</button>)}</div>
          {availableTags.length > 0 ? <select defaultValue="" disabled={saving} onChange={(event) => { if (event.target.value) void assignTag(event.target.value); event.target.value = '' }}><option value="">Add existing tag</option>{availableTags.map((tag) => <option key={tag.id} value={tag.id}>{tag.name}</option>)}</select> : null}
          <div className="inline-form"><input placeholder="New tag" value={newTag} onChange={(event) => setNewTag(event.target.value)} /><button type="button" className="text-btn" disabled={saving} onClick={() => void createTag()}>Create</button></div>
        </section>
        <section className="customer-section"><h3>Notes</h3><textarea rows={3} placeholder="Add a private note" value={note} onChange={(event) => setNote(event.target.value)} /><button type="button" className="btn" disabled={saving || !note.trim()} onClick={() => void addNote()}>Save note</button>
          <ul className="note-list">{notes.map((item) => <li key={item.id}><p>{item.body}</p><span>{formatDate(item.created_at)}</span></li>)}</ul>
        </section>
        <section className="customer-section"><h3>Order history</h3><ul className="customer-orders">{history.map((item) => <li key={item.id}><span>#{item.receipt_code} · {formatDate(item.created_at)}</span><strong>{formatPrice(Number(item.total_price) / 100, item.currency)}</strong></li>)}</ul></section>
      </>}
    </aside>
  )
}
