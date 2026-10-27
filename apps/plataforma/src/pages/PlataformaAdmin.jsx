import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Plus, Trash2 } from 'lucide-react';

import { adminApi } from '@/shared/api/adminApi';
import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  MoneyLoader,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  useToast,
} from '@/shared/ui';

import { useAuth } from '@/lib/AuthContext';

const adminsKey = ['servicos', 'admin-plataforma-admins'];
const auditoriaKey = ['servicos', 'admin-plataforma-auditoria'];

const ROTULOS_ACAO = {
  tenant_criar: 'Cliente criado',
  tenant_atualizar: 'Cliente atualizado',
  tenant_admin_resetar_senha: 'Senha de administrador de cliente redefinida',
  admin_adicionar: 'Administrador da plataforma adicionado',
  admin_remover: 'Administrador da plataforma removido',
  usuario_criar: 'Usuário criado',
  usuario_atualizar: 'Usuário atualizado',
  usuario_resetar_senha: 'Senha de usuário redefinida',
  cadastro_salvar: 'Cadastro salvo',
  cadastro_excluir: 'Cadastro excluído',
  integracao_gmail_salvar: 'Integração de e-mail salva',
  catalogo_salvar: 'Catálogo de veículos salvo',
  catalogo_excluir: 'Item do catálogo de veículos excluído',
};

function resumoDetalhes(detalhes) {
  return Object.entries(detalhes || {})
    .filter(([chave]) => chave !== 'id' && chave !== 'user_id')
    .map(([chave, valor]) => `${chave}: ${valor}`)
    .join(' · ');
}

export function AdministradoresTab() {
  const { toast } = useToast();
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const meuId = user?.id || null;
  const [email, setEmail] = useState('');
  const [remover, setRemover] = useState(null);

  const query = useQuery({ queryKey: adminsKey, queryFn: () => adminApi.plataforma.admins() });
  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: adminsKey });
    queryClient.invalidateQueries({ queryKey: auditoriaKey });
  };

  const adicionarMutation = useMutation({
    mutationFn: () => adminApi.plataforma.adicionarAdmin(email.trim()),
    onSuccess: () => {
      toast({ title: 'Administrador adicionado' });
      setEmail('');
      refresh();
    },
    onError: (error) => toast({ title: 'Não foi possível adicionar', description: error.message }),
  });

  const removerMutation = useMutation({
    mutationFn: (userId) => adminApi.plataforma.removerAdmin(userId),
    onSuccess: () => {
      toast({ title: 'Administrador removido' });
      setRemover(null);
      refresh();
    },
    onError: (error) => {
      setRemover(null);
      toast({ title: 'Não foi possível remover', description: error.message });
    },
  });

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-bold">Administradores da plataforma</h2>
        <p className="text-sm text-muted-foreground">
          Quem pode criar e desativar clientes. O usuário precisa já existir (criado em algum cliente).
        </p>
      </div>

      <div className="flex max-w-xl gap-2">
        <Input type="email" placeholder="E-mail do usuário" value={email} onChange={(e) => setEmail(e.target.value)} />
        <Button disabled={!email.trim() || adicionarMutation.isPending} onClick={() => adicionarMutation.mutate()}>
          <Plus className="mr-1 h-4 w-4" /> Adicionar
        </Button>
      </div>

      {query.isLoading ? (
        <MoneyLoader inline />
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Usuário</TableHead>
                <TableHead>Cliente</TableHead>
                <TableHead>Desde</TableHead>
                <TableHead className="text-right">Ações</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(query.data || []).map((row) => (
                <TableRow key={row.user_id}>
                  <TableCell>
                    <div className="font-medium">{row.nome || row.email}</div>
                    <div className="text-xs text-muted-foreground">{row.email}</div>
                  </TableCell>
                  <TableCell>{row.cliente || '—'}</TableCell>
                  <TableCell>{new Date(row.criado_em).toLocaleDateString('pt-BR')}</TableCell>
                  <TableCell className="text-right">
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label="Remover"
                      disabled={row.user_id === meuId}
                      onClick={() => setRemover(row)}
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      <Dialog open={Boolean(remover)} onOpenChange={(open) => !open && setRemover(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Remover administrador</DialogTitle>
            <DialogDescription>
              {remover?.email} deixa de ter acesso ao painel da plataforma. O usuário e o cliente dele continuam existindo.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setRemover(null)}>
              Cancelar
            </Button>
            <Button disabled={removerMutation.isPending} onClick={() => removerMutation.mutate(remover.user_id)}>
              Remover
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

export function AuditoriaTab() {
  const query = useQuery({ queryKey: auditoriaKey, queryFn: () => adminApi.plataforma.auditoria() });
  const rows = query.data || [];

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-bold">Auditoria</h2>
        <p className="text-sm text-muted-foreground">
          Últimas 300 ações administrativas: quem fez, quando e em qual cliente. Senhas e segredos nunca são registrados.
        </p>
      </div>

      {query.isLoading ? (
        <MoneyLoader inline />
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">Nenhuma ação registrada ainda.</p>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Quando</TableHead>
                <TableHead>Quem</TableHead>
                <TableHead>Ação</TableHead>
                <TableHead>Cliente</TableHead>
                <TableHead>Detalhes</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="whitespace-nowrap text-sm">{new Date(row.criado_em).toLocaleString('pt-BR')}</TableCell>
                  <TableCell className="text-sm">{row.ator_email || '—'}</TableCell>
                  <TableCell className="text-sm font-medium">{ROTULOS_ACAO[row.acao] || row.acao}</TableCell>
                  <TableCell className="text-sm">{row.tenant_nome || '—'}</TableCell>
                  <TableCell className="max-w-md truncate text-xs text-muted-foreground" title={resumoDetalhes(row.detalhes)}>
                    {resumoDetalhes(row.detalhes)}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}
