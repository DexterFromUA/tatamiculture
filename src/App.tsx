import { Navigate, Outlet, Route, Routes, useParams } from 'react-router-dom'
import { ProtectedRoute } from './components/ProtectedRoute'
import { StoreLayout } from './components/StoreLayout'
import { CartProvider } from './context/CartContext'
import { StoreProvider } from './context/StoreContext'
import { AccountPage } from './pages/AccountPage'
import { AdminPage } from './pages/AdminPage'
import { CartPage } from './pages/CartPage'
import { CatalogAdminPage } from './pages/CatalogAdminPage'
import { CatalogPage } from './pages/CatalogPage'
import { CheckoutPage } from './pages/CheckoutPage'
import { LoginPage } from './pages/LoginPage'
import { NotFoundPage } from './pages/NotFoundPage'
import { ProductPage } from './pages/ProductPage'
import { QuickBuyPage } from './pages/QuickBuyPage'
import { ReceiptPage } from './pages/ReceiptPage'
import { RegisterPage } from './pages/RegisterPage'

function StoreTree() {
  return (
    <StoreProvider slug="tatami">
      <CartProvider>
        <Outlet />
      </CartProvider>
    </StoreProvider>
  )
}

function LegacyStoreRedirect() {
  const { '*': rest } = useParams()
  return <Navigate to={rest ? `/${rest}` : '/'} replace />
}

export default function App() {
  return (
    <Routes>
      <Route path="/q/:code" element={<QuickBuyPage />} />
      <Route path="/" element={<StoreTree />}>
        <Route element={<StoreLayout />}>
          <Route index element={<CatalogPage />} />
          <Route path="product/:productId" element={<ProductPage />} />
          <Route path="cart" element={<CartPage />} />
          <Route path="checkout" element={<CheckoutPage />} />
          <Route path="login" element={<LoginPage />} />
          <Route path="register" element={<RegisterPage />} />
          <Route path="receipt/:code" element={<ReceiptPage />} />
          <Route
            path="orders"
            element={
              <ProtectedRoute>
                <AccountPage />
              </ProtectedRoute>
            }
          />
          <Route
            path="account"
            element={
              <ProtectedRoute>
                <AccountPage />
              </ProtectedRoute>
            }
          />
          <Route
            path="admin"
            element={
              <ProtectedRoute>
                <AdminPage />
              </ProtectedRoute>
            }
          />
          <Route
            path="admin/catalog"
            element={
              <ProtectedRoute>
                <CatalogAdminPage />
              </ProtectedRoute>
            }
          />
          <Route path="*" element={<NotFoundPage />} />
        </Route>
      </Route>
      <Route path="/tatami/*" element={<LegacyStoreRedirect />} />
      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  )
}
