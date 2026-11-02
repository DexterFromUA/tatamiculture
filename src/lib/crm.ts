import { supabaseRequest } from './supabase'

// PostgREST defaults to a capped result set; fetch every page for exports and aggregates.
export async function fetchAll<T>(path: string, token: string, signal?: AbortSignal): Promise<T[]> {
  const result: T[] = []
  for (let offset = 0; ; ) {
    const rows = await supabaseRequest<T[]>(`${path}&limit=500&offset=${offset}`, { token, signal })
    result.push(...rows)
    if (!rows.length) return result
    offset += rows.length
  }
}

export function downloadCsv(filename: string, rows: unknown[][]) {
  const quote = (value: unknown) => {
    let text = String(value ?? '')
    if (/^\s*[=+@-]/.test(text)) text = `'${text}`
    return `"${text.replaceAll('"', '""')}"`
  }
  const url = URL.createObjectURL(new Blob(['\uFEFF', rows.map(row => row.map(quote).join(';')).join('\r\n')], { type: 'text/csv;charset=utf-8' }))
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  link.click()
  window.setTimeout(() => URL.revokeObjectURL(url), 1000)
}
