// Rodape de credito compartilhado entre apps: nome da organizacao (opcional) + credito (opcional). Presentational, sem fetch.
export function AppFooter({ orgName = '', credit = '', className = '' }) {
  const year = new Date().getFullYear();
  return (
    <p className={`text-center text-[10px] text-muted-foreground ${className}`}>
      {[orgName ? `${orgName} © ${year}` : `© ${year}`, credit].filter(Boolean).join(' · ')}
    </p>
  );
}
