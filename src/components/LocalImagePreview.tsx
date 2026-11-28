import { useEffect, useState } from 'react'

export function LocalImagePreview({ file }: { file: File }) {
  const [url, setUrl] = useState('')
  useEffect(() => {
    const url = URL.createObjectURL(file)
    setUrl(url)
    return () => URL.revokeObjectURL(url)
  }, [file])
  return file.type.startsWith('video/')
    ? <video src={url} muted playsInline preload="metadata" />
    : <img src={url} alt={file.name} draggable={false} />
}
