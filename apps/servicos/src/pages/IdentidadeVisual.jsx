import { useQuery } from '@tanstack/react-query';

import { adminApi } from '@/shared/api/adminApi';
import { BrandForm, MoneyLoader, useToast } from '@/shared/ui';
import { useBrand } from '@/lib/BrandContext';
import { appUrl } from '@/lib/tenant';

// Aba de Configuracoes: o admin do cliente ajusta nome, cor e logo da propria empresa.
export default function IdentidadeVisual() {
  const { toast } = useToast();
  const { reload } = useBrand();
  const query = useQuery({ queryKey: ['servicos', 'admin-marca'], queryFn: () => adminApi.marca.obter(), staleTime: 0 });

  if (query.isLoading) return <MoneyLoader inline />;
  if (query.isError) return <p className="text-sm text-destructive">{query.error.message}</p>;

  return (
    <div className="max-w-xl space-y-4">
      <div>
        <h2 className="text-lg font-semibold">Identidade visual</h2>
        <p className="text-sm text-muted-foreground">
          Personalize o nome, a cor, o logo e o fundo da tela de login que seus usuários veem. Endereço de acesso:{' '}
          <span className="select-all font-mono">{appUrl('/')}</span>
        </p>
      </div>
      <BrandForm
        marca={query.data}
        onSave={async (payload) => {
          await adminApi.marca.salvar(payload);
          await query.refetch();
          await reload();
          toast({ title: 'Identidade visual atualizada' });
        }}
      />
    </div>
  );
}
