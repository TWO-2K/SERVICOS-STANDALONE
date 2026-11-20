import { writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';
import { VitePWA } from 'vite-plugin-pwa';

const appRoot = fileURLToPath(new URL('.', import.meta.url));
const { version: appVersion } = createRequire(import.meta.url)('./package.json');

// Gera version.json no dist, fora do bundle/SW cache -- e o unico jeito da pagina ainda rodando a
// versao antiga descobrir o numero da versao NOVA antes do usuario clicar em "Atualizar" no toast
// do AppUpdatePrompt.jsx (o numero so existe dentro do bundle novo, que so roda depois do reload).
// Buscado com cache: 'no-store' pra sempre pegar o arquivo publicado no deploy mais recente.
function versionJsonPlugin() {
  let outDir;
  return {
    name: 'servicos-version-json',
    configResolved(config) {
      outDir = config.build.outDir;
    },
    writeBundle() {
      writeFileSync(`${outDir}/version.json`, JSON.stringify({ version: appVersion }));
    },
  };
}

export default defineConfig({
  root: appRoot,
  // .env.local fica na raiz do projeto (VITE_SUPABASE_URL etc.).
  envDir: path.resolve(appRoot, '../..'),
  logLevel: 'error',
  server: { port: 5177, strictPort: true },
  preview: { port: 4177, strictPort: true },
  define: { __APP_VERSION__: JSON.stringify(appVersion) },
  resolve: {
    alias: { '@': path.resolve(appRoot, './src') },
  },
  build: {
    outDir: path.resolve(appRoot, './dist'),
    emptyOutDir: true,
  },
  plugins: [
    react(),
    versionJsonPlugin(),
    VitePWA({
      strategies: 'injectManifest',
      srcDir: 'src',
      filename: 'sw.js',
      registerType: 'prompt',
      injectRegister: false,
      manifestFilename: 'manifest.json',
      includeAssets: ['favicon.svg', 'pwa-icons/*.png'],
      manifest: {
        id: '/',
        name: process.env.VITE_APP_NAME || 'K-Pit',
        short_name: process.env.VITE_APP_NAME || 'K-Pit',
        description: 'Atendimento, oficina, financeiro, estoque, compras e RH.',
        start_url: '/',
        scope: '/',
        display: 'standalone',
        background_color: '#f5f5f5',
        theme_color: '#1F2937',
        icons: [
          { src: '/pwa-icons/pwa-192x192.png', sizes: '192x192', type: 'image/png' },
          { src: '/pwa-icons/pwa-512x512.png', sizes: '512x512', type: 'image/png' },
          { src: '/pwa-icons/maskable-icon-512x512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
      injectManifest: {
        globPatterns: ['**/*.{js,css,html,svg,woff2,woff,png,ico}'],
        // Imagens pesadas (diagrama de veiculo, oficina) sao webp e ficam fora do precache de
        // proposito -- cacheadas sob demanda pela rota CacheFirst em src/sw.js, nao no boot do app.
        globIgnores: ['**/assets/oficina/*.webp'],
        maximumFileSizeToCacheInBytes: 4 * 1024 * 1024,
      },
      devOptions: { enabled: false },
    }),
  ],
});
