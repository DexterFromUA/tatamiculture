import { Link } from 'react-router-dom'

export function NotFoundPage() {
  return (
    <section className="page-status">
      <h1>Page not found</h1>
      <Link to="/">Back to shop</Link>
    </section>
  )
}
