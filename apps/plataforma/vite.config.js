import path from 'node:path';
import { fileURLToPath } from 'node:url';

import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

const appRoot = fileURLToPath(new URL('.', import.meta.url));

// Painel da plataforma: app proprio (subdominio proprio em producao), sem PWA. Reaproveita a camada
// compartilhada (UI, clientes de API, validacao) do app dos clientes por alias, sem copiar codigo.
export default defineConfig({
  root: appRoot,
  // .env.local fica na raiz do projeto (VITE_SUPABASE_URL etc.).
  envDir: path.resolve(appRoot, '../..'),
  logLevel: 'error',
  server: { port: 5178, strictPort: true, fs: { allow: [path.resolve(appRoot, '..')] } },
  preview: { port: 4178, strictPort: true },
  resolve: {
    alias: [
      { find: /^@\/shared\//, replacement: `${path.resolve(appRoot, '../servicos/src/shared')}/` },
      { find: /^@\//, replacement: `${path.resolve(appRoot, './src')}/` },
    ],
  },
  build: {
    outDir: path.resolve(appRoot, './dist'),
    emptyOutDir: true,
  },
  plugins: [react()],
});
