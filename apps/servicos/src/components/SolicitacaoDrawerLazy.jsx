import { lazy, Suspense, useState } from 'react';

// SolicitacaoDrawer arrasta pdf-lib e o fluxo de assinatura; so baixa quando alguem abre uma
// solicitacao pela primeira vez. Depois disso fica montado, pra animacao de fechar funcionar.
// Mesma API do componente original.
const SolicitacaoDrawer = lazy(() => import('@/components/SolicitacaoDrawer'));

export default function SolicitacaoDrawerLazy(props) {
  const [abriu, setAbriu] = useState(false);
  if (props.solicitacao && !abriu) setAbriu(true);
  if (!abriu) return null;

  return (
    <Suspense fallback={null}>
      <SolicitacaoDrawer {...props} />
    </Suspense>
  );
}
