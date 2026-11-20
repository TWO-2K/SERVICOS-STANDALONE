// Identidade padrao do produto. O nome e o logo da EMPRESA do cliente vem do backend (ver BrandContext.jsx); aqui
// ficam so o nome do produto (usado como subtitulo) e o logo de fallback, configuraveis por variavel de build.
export const APP_NAME = import.meta.env.VITE_APP_NAME || 'K-Pit';
export const LOGO_URL = import.meta.env.VITE_LOGO_URL || '/favicon.svg';
// Sem valor aqui e sem fundo definido pelo cliente, o login usa o gradiente padrao (generico) do AuthLoginCard.
export const LOGIN_BACKGROUND_URL = import.meta.env.VITE_LOGIN_BACKGROUND_URL || null;
