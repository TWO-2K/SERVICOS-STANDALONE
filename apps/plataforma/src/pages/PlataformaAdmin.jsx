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
  Label,
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
  tenant_excluir: 'Cliente excluído',
  tenant_admin_resetar_senha: 'Senha de administrador de cliente redefinida',
  admin_criar: 'Administrador da plataforma criado',
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
  const [novoAberto, setNovoAberto] = useState(false);
  const [nome, setNome] = useState('');
  const [email, setEmail] = useState('');
  const [resultado, setResultado] = useState(null);
  const [remover, setRemover] = useState(null);

  const query = useQuery({ queryKey: adminsKey, queryFn: () => adminApi.plataforma.admins() });
  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: adminsKey });
    queryClient.invalidateQueries({ queryKey: auditoriaKey });
  };

  const fecharNovo = () => {
    setNovoAberto(false);
    setNome('');
    setEmail('');
    setResultado(null);
  };

  const criarMutation = useMutation({
    mutationFn: () => adminApi.plataforma.criarAdmin({ nome: nome.trim(), email: email.trim() }),
    onSuccess: ({ row }) => {
      setResultado({ email: row.email, senha: row.senha_temporaria, emailEnviado: row.email_enviado });
      refresh();
    },
    onError: (error) => toast({ title: 'Não foi possível criar o administrador', description: error.message }),
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
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-xl font-bold">Administradores da plataforma</h2>
          <p className="text-sm text-muted-foreground">
            Quem pode criar e desativar clientes. A conta é exclusiva da plataforma: não acessa o sistema de nenhum cliente.
          </p>
        </div>
        <Button onClick={() => setNovoAberto(true)}>
          <Plus className="mr-1 h-4 w-4" /> Novo administrador
        </Button>
      </div>

      <Dialog open={novoAberto} onOpenChange={(aberto) => !aberto && fecharNovo()}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Novo administrador da plataforma</DialogTitle>
            <DialogDescription>
              {resultado
                ? resultado.emailEnviado
                  ? `Enviamos o acesso para ${resultado.email}.`
                  : 'Envie os dados abaixo ao administrador. A senha não será exibida novamente.'
                : 'Cria uma conta nova com senha temporária. Use um e-mail que ainda não tenha conta.'}
            </DialogDescription>
          </DialogHeader>
          {resultado?.emailEnviado ? null : resultado ? (
            <div className="space-y-1 rounded-md border bg-muted p-3 text-sm">
              <div>
                <span className="text-muted-foreground">E-mail:</span> {resultado.email}
              </div>
              <div>
                <span className="text-muted-foreground">Senha:</span>{' '}
                <code className="select-all font-mono">{resultado.senha}</code>
              </div>
            </div>
          ) : (
            <div className="space-y-3">
              <div className="space-y-1">
                <Label htmlFor="novo-adm-nome">Nome</Label>
                <Input id="novo-adm-nome" value={nome} onChange={(e) => setNome(e.target.value)} />
              </div>
              <div className="space-y-1">
                <Label htmlFor="novo-adm-email">E-mail</Label>
                <Input id="novo-adm-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
              </div>
            </div>
          )}
          <DialogFooter>
            {resultado ? null : (
              <Button disabled={criarMutation.isPending || !nome.trim() || !email.trim()} onClick={() => criarMutation.mutate()}>
                {criarMutation.isPending ? 'Criando...' : 'Criar administrador'}
              </Button>
            )}
            <Button variant="outline" onClick={fecharNovo}>
              Fechar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {query.isLoading ? (
        <MoneyLoader inline />
      ) : query.isError ? (
        <p className="text-sm text-destructive">
          Não foi possível carregar os administradores: {query.error?.message || 'erro desconhecido'}. Saia e entre de novo.
        </p>
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
