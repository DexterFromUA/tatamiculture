import type { Product, ShortLink, Store, User } from '../types'

export const DEMO_SMS_CODE = '123456'

export const stores: Store[] = [
  {
    id: 'store_tatami',
    slug: 'tatami',
    name: 'Tatami.Culture',
    description: 'Спортивний одяг для тренувань, руху та щоденного ритму.',
    contactEmail: 'hello@tatami.store',
    contactPhone: '+380 50 123 4567',
    contactCity: 'Kyiv',
    currency: 'UAH',
    primaryColor: '#203f36',
  },
]

export const demoUser: User = {
  id: 'user_anna',
  name: 'Anna Koval',
  email: 'anna@example.com',
  phone: '+380501234567',
  city: 'Kyiv',
}

export const products: Product[] = [
  {
    id: 'p_hoodie',
    storeId: 'store_tatami',
    name: 'Training hoodie',
    description: 'Щільне худі вільного крою для розминки та відновлення після тренування.',
    category: 'Hoodies',
    imgUrls: ['https://images.unsplash.com/photo-1539533018447-63fcce2678e3?auto=format&fit=crop&w=800&q=80'],
    isActive: true,
    productOptions: [
      { id: 'o_hoodie_s', name: 'S', price: 2490, isPreOrder: false, isDiscount: false, discountPercent: 0, isLimited: true, quantity: 4 },
      { id: 'o_hoodie_m', name: 'M', price: 2490, isPreOrder: false, isDiscount: false, discountPercent: 0, isLimited: true, quantity: 6 },
      { id: 'o_hoodie_l', name: 'L', price: 2490, isPreOrder: false, isDiscount: true, discountPercent: 15, isLimited: true, quantity: 2 },
    ],
  },
  {
    id: 'p_tshirt',
    storeId: 'store_tatami',
    name: 'Performance T-shirt',
    description: 'Легка футболка, що відводить вологу та не сковує рухи.',
    category: 'T-shirts',
    imgUrls: ['https://images.unsplash.com/photo-1596755094514-f87e34085b2c?auto=format&fit=crop&w=800&q=80'],
    isActive: true,
    productOptions: [
      { id: 'o_tshirt_white', name: 'White / M', price: 1290, isPreOrder: false, isDiscount: false, discountPercent: 0, isLimited: false, quantity: 20 },
      { id: 'o_tshirt_black', name: 'Black / M', price: 1290, isPreOrder: false, isDiscount: false, discountPercent: 0, isLimited: false, quantity: 12 },
    ],
  },
  {
    id: 'p_joggers',
    storeId: 'store_tatami',
    name: 'Everyday joggers',
    description: 'М’які джогери із високою посадкою для залу й міста.',
    category: 'Bottoms',
    imgUrls: ['https://images.unsplash.com/photo-1594938298603-c8148c4dae35?auto=format&fit=crop&w=800&q=80'],
    isActive: true,
    productOptions: [
      { id: 'o_joggers_s', name: 'S', price: 2190, isPreOrder: false, isDiscount: false, discountPercent: 0, isLimited: true, quantity: 5 },
      { id: 'o_joggers_m', name: 'M', price: 2190, isPreOrder: false, isDiscount: false, discountPercent: 0, isLimited: true, quantity: 8 },
    ],
  },
  {
    id: 'p_top',
    storeId: 'store_tatami',
    name: 'Seamless training top',
    description: 'Безшовний топ середньої підтримки для функціональних тренувань.',
    category: 'Training tops',
    imgUrls: ['https://images.unsplash.com/photo-1434389677669-e08b4cac3105?auto=format&fit=crop&w=800&q=80'],
    isActive: true,
    productOptions: [
      { id: 'o_top_s', name: 'S', price: 1190, isPreOrder: true, isDiscount: false, discountPercent: 0, isLimited: false, quantity: 0 },
      { id: 'o_top_m', name: 'M', price: 1190, isPreOrder: true, isDiscount: false, discountPercent: 0, isLimited: false, quantity: 0 },
    ],
  },
  {
    id: 'p_bag',
    storeId: 'store_tatami',
    name: 'Gym tote',
    description: 'Легка містка сумка для форми, води та кросівок.',
    category: 'Accessories',
    imgUrls: ['https://images.unsplash.com/photo-1548036328-c9fa89d128fa?auto=format&fit=crop&w=800&q=80'],
    isActive: true,
    productOptions: [
      { id: 'o_bag_one', name: 'One size', price: 1590, isPreOrder: false, isDiscount: true, discountPercent: 10, isLimited: true, quantity: 3 },
    ],
  },
  {
    id: 'p_leggings',
    storeId: 'store_tatami',
    name: 'Move leggings',
    description: 'Еластичні легінси з високим поясом для бігу, йоги та силових вправ.',
    category: 'Leggings',
    imgUrls: ['https://images.unsplash.com/photo-1608256246200-53e635b5b65f?auto=format&fit=crop&w=800&q=80'],
    isActive: true,
    productOptions: [
      { id: 'o_leggings_s', name: 'S', price: 1890, isPreOrder: false, isDiscount: false, discountPercent: 0, isLimited: true, quantity: 2 },
      { id: 'o_leggings_m', name: 'M', price: 1890, isPreOrder: false, isDiscount: false, discountPercent: 0, isLimited: true, quantity: 4 },
      { id: 'o_leggings_l', name: 'L', price: 1890, isPreOrder: false, isDiscount: false, discountPercent: 0, isLimited: true, quantity: 1 },
    ],
  },
]

export const shortLinks: ShortLink[] = [
  { id: 'sl_1', code: 'hoodie24', storeId: 'store_tatami', productId: 'p_hoodie' },
]
