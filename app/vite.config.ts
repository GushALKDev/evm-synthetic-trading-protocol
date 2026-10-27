import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig(({ mode }) => ({
  plugins: [react()],
  // The market e2e server runs in its own mode, so it keeps its own dependency optimizer cache (playwright.config.ts)
  cacheDir: mode === 'market' ? 'node_modules/.vite-market' : 'node_modules/.vite',
  build: {
    target: 'es2022',
    sourcemap: true,
    rollupOptions: {
      output: {
        manualChunks: (id) => {
          if (/node_modules\/(viem|ox|abitype|@noble|@scure)\//.test(id)) return 'viem'
          if (/node_modules\/(wagmi|@wagmi|@tanstack)\//.test(id)) return 'wagmi'
          if (/node_modules\/(react|react-dom|scheduler)\//.test(id)) return 'react'
        },
      },
    },
  },
  test: { environment: 'node', include: ['src/**/*.test.ts', 'scripts/**/*.test.ts'] },
}))
