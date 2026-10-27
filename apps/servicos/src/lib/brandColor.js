// Converte a cor da marca (#RRGGBB) nas variaveis HSL do tema e escolhe texto claro/escuro com bom contraste.
function hexToHsl(hex) {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  const d = max - min;
  let h = 0;
  let s = 0;
  if (d !== 0) {
    s = d / (1 - Math.abs(2 * l - 1));
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h = Math.round(h * 60);
    if (h < 0) h += 360;
  }
  return { h, s: Math.round(s * 100), l: Math.round(l * 100), luminance: 0.299 * r + 0.587 * g + 0.114 * b };
}

const VARS = ['--primary', '--primary-foreground', '--ring', '--sidebar-primary', '--sidebar-primary-foreground', '--sidebar-ring'];

export function applyBrandColor(hex) {
  const root = document.documentElement;
  if (!/^#[0-9a-f]{6}$/i.test(hex || '')) {
    VARS.forEach((name) => root.style.removeProperty(name));
    return;
  }
  const { h, s, l, luminance } = hexToHsl(hex);
  const color = `${h} ${s}% ${l}%`;
  const foreground = luminance > 0.6 ? '0 0% 10%' : '0 0% 100%';
  root.style.setProperty('--primary', color);
  root.style.setProperty('--ring', color);
  root.style.setProperty('--sidebar-primary', color);
  root.style.setProperty('--sidebar-ring', color);
  root.style.setProperty('--primary-foreground', foreground);
  root.style.setProperty('--sidebar-primary-foreground', foreground);
}
