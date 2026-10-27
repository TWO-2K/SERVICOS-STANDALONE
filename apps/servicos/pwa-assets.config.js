import { defineConfig, minimal2023Preset } from '@vite-pwa/assets-generator/config';

// Fonte: public/favicon.svg (fundo transparente). Usar um PNG com
// fundo solido aqui reintroduz o bug do quadrado vermelho no instalavel PWA/preview de link, ja
// visto em producao -- nao trocar de volta.
export default defineConfig({
  preset: minimal2023Preset,
  images: ['public/favicon.svg'],
});
