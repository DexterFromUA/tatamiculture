import react, { reactCompilerPreset } from '@vitejs/plugin-react'
import babel from '@rolldown/plugin-babel'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
    babel({ presets: [reactCompilerPreset()] })
  ],
  server: {
    proxy: {
      '^/__manto-source/(?:product-eng-\\d+(?:-[^/?#]+)?\\.html|(?:hpeciai/|data/include/cms/|data/gfx/pictures/)[^?#]+\\.(?:webp|jpe?g|png))$': {
        target: 'https://www.mantoshop.eu',
        changeOrigin: true,
        rewrite: path => path.slice('/__manto-source'.length),
        proxyTimeout: 8000,
        configure(proxy) {
          proxy.on('proxyReq', request => {
            for (const header of ['authorization', 'cookie', 'origin', 'referer']) request.removeHeader(header)
          })
        },
      },
    },
  },
})
