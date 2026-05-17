import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import checker from 'vite-plugin-checker'

// `vite-plugin-checker` runs `tsc` in the background during `vite dev`, so the
// same type errors that fail the production `tsc -b` build show up in the
// browser overlay + terminal immediately. Match the build command in package.json
// (`tsc -b`) so the dev signal lines up exactly with what CI runs.
export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    checker({ typescript: { buildMode: true } }),
  ],
  server: {
    host: '0.0.0.0',
    port: 5173,
  },
})
