import react, { reactCompilerPreset } from '@vitejs/plugin-react'
import babel from '@rolldown/plugin-babel'
import { defineConfig, type ProxyOptions } from 'vite'

function mantoProxy(market: 'eu' | 'pl'): [string, ProxyOptions] {
  const prefix = `/__manto-source/${market}`
  const locale = market === 'pl' ? 'pol' : 'eng'
  const pattern = `^${prefix}/(?:product-${locale}-\\d+(?:-[^/?#]+)?\\.html|(?:hpeciai/|data/include/cms/|data/gfx/pictures/)[^?#]+\\.(?:webp|jpe?g|png))$`
  return [pattern, {
    target: `https://www.mantoshop.${market}`,
    changeOrigin: true,
    rewrite: path => path.slice(prefix.length),
    proxyTimeout: 8000,
    configure(proxy) {
      proxy.on('proxyReq', request => {
        for (const header of ['authorization', 'cookie', 'origin', 'referer']) request.removeHeader(header)
      })
    },
  }]
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
    babel({ presets: [reactCompilerPreset()] })
  ],
  server: {
    proxy: Object.fromEntries([mantoProxy('eu'), mantoProxy('pl')]),
  },
})
