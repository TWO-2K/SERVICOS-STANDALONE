import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { KeyRound, Pencil, Plus } from 'lucide-react';

import { adminApi } from '@/shared/api/adminApi';
import {
  Badge,
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
  Switch,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  useToast,
} from '@/shared/ui';

import { useAdminMe } from '@/hooks/useAdminMe';
import { EditarClienteDialog, RedefinirSenhaAdminDialog } from '@/pages/PlataformaClienteDialogs';
import { AdministradoresTab, AuditoriaTab } from '@/pages/PlataformaAdmin';
import { CatalogosTab } from '@/pages/PlataformaCatalogos';

const tenantsKey = ['servicos', 'admin-tenants'];
const FORM_VAZIO = { nome: '', slug: '', admin_nome: '', admin_email: '' };

function slugify(texto) {
  return texto
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40);
}

function ClientesTab() {
  const { toast } = useToast();
  const queryClient = useQueryClient();
  const meuTenantId = useAdminMe().tenant?.id || null;
  const [criarAberto, setCriarAberto] = useState(false);
  const [form, setForm] = useState(FORM_VAZIO);
  const [slugEditado, setSlugEditado] = useState(false);
  const [credenciais, setCredenciais] = useState(null);
  const [editando, setEditando] = useState(null);
  const [redefinindo, setRedefinindo] = useState(null);

  const query = useQuery({ queryKey: tenantsKey, queryFn: () => adminApi.tenants.list() });
  const rows = query.data || [];
  const refresh = () => queryClient.invalidateQueries({ queryKey: tenantsKey });

  const criarMutation = useMutation({
    mutationFn: () => adminApi.tenants.criar(form),
    onSuccess: (result) => {
      setCriarAberto(false);
      setCredenciais({ cliente: result.tenant.nome, email: result.admin.email, senha: result.admin.senha_temporaria });
      setForm(FORM_VAZIO);
      setSlugEditado(false);
      refresh();
    },
    onError: (error) => toast({ title: 'Não foi possível criar o cliente', description: error.message }),
  });

  const atualizarMutation = useMutation({
    mutationFn: ({ id, dados }) => adminApi.tenants.atualizar(id, dados),
    onSuccess: (row) => {
      toast({ title: row.ativo ? 'Cliente ativado' : 'Cliente desativado' });
      refresh();
    },
    onError: (error) => toast({ title: 'Não foi possível atualizar o cliente', description: error.message }),
  });

  const podeSalvar =
    form.nome.trim() && form.slug.trim() && form.admin_nome.trim() && form.admin_email.trim() && !criarMutation.isPending;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-xl font-bold">Clientes</h2>
          <p className="text-sm text-muted-foreground">
            Clientes (empresas contratantes) do sistema. Cada cliente enxerga só os próprios dados. Desativar bloqueia o
            acesso aos dados sem apagar nada.
          </p>
        </div>
        <Button onClick={() => setCriarAberto(true)}>
          <Plus className="mr-1 h-4 w-4" /> Novo cliente
        </Button>
      </div>

      {query.isLoading ? (
        <MoneyLoader inline />
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Cliente</TableHead>
                <TableHead>Plano</TableHead>
                <TableHead className="text-right">Usuários</TableHead>
                <TableHead className="text-right">Solicitações</TableHead>
                <TableHead>Criado em</TableHead>
                <TableHead className="text-right">Ativo</TableHead>
                <TableHead className="text-right">Ações</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id}>
                  <TableCell>
                    <div className="font-medium">{row.nome}</div>
                    <div className="text-xs text-muted-foreground">{row.slug}</div>
                  </TableCell>
                  <TableCell>
                    <Badge variant="outline">{row.plano}</Badge>
                  </TableCell>
                  <TableCell className="text-right">{row.usuarios}</TableCell>
                  <TableCell className="text-right">{row.solicitacoes}</TableCell>
                  <TableCell>{new Date(row.criado_em).toLocaleDateString('pt-BR')}</TableCell>
                  <TableCell className="text-right">
                    <Switch
                      checked={row.ativo}
                      disabled={atualizarMutation.isPending || row.id === meuTenantId}
                      onCheckedChange={(ativo) => atualizarMutation.mutate({ id: row.id, dados: { ativo } })}
                    />
                  </TableCell>
                  <TableCell className="text-right">
                    <Button variant="ghost" size="icon" aria-label="Editar cliente" onClick={() => setEditando(row)}>
                      <Pencil className="h-4 w-4" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label="Redefinir senha do administrador"
                      onClick={() => setRedefinindo(row)}
                    >
                      <KeyRound className="h-4 w-4" />
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      <EditarClienteDialog cliente={editando} onClose={() => setEditando(null)} onSalvo={refresh} />
      <RedefinirSenhaAdminDialog cliente={redefinindo} onClose={() => setRedefinindo(null)} />

      <Dialog open={criarAberto} onOpenChange={setCriarAberto}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Novo cliente</DialogTitle>
            <DialogDescription>
              Cria o cliente, a empresa inicial e o administrador dele, com senha temporária.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1">
              <Label htmlFor="tenant-nome">Nome do cliente</Label>
              <Input
                id="tenant-nome"
                value={form.nome}
                onChange={(e) => {
                  const nome = e.target.value;
                  setForm({ ...form, nome, slug: slugEditado ? form.slug : slugify(nome) });
                }}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="tenant-slug">Identificador (slug)</Label>
              <Input
                id="tenant-slug"
                value={form.slug}
                onChange={(e) => {
                  setSlugEditado(true);
                  setForm({ ...form, slug: slugify(e.target.value) });
                }}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="tenant-admin-nome">Nome do administrador</Label>
              <Input
                id="tenant-admin-nome"
                value={form.admin_nome}
                onChange={(e) => setForm({ ...form, admin_nome: e.target.value })}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="tenant-admin-email">E-mail do administrador</Label>
              <Input
                id="tenant-admin-email"
                type="email"
                value={form.admin_email}
                onChange={(e) => setForm({ ...form, admin_email: e.target.value })}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCriarAberto(false)}>
              Cancelar
            </Button>
            <Button disabled={!podeSalvar} onClick={() => criarMutation.mutate()}>
              {criarMutation.isPending ? 'Criando...' : 'Criar cliente'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(credenciais)} onOpenChange={(open) => !open && setCredenciais(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Cliente criado</DialogTitle>
            <DialogDescription>
              Envie estes dados ao administrador de {credenciais?.cliente}. A senha não será exibida novamente.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-1 rounded-md border bg-muted p-3 text-sm">
            <div>
              <span className="text-muted-foreground">E-mail:</span> {credenciais?.email}
            </div>
            <div>
              <span className="text-muted-foreground">Senha:</span>{' '}
              <code className="select-all font-mono">{credenciais?.senha}</code>
            </div>
          </div>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() =>
                navigator.clipboard?.writeText(credenciais?.senha || '').then(() => toast({ title: 'Senha copiada' }))
              }
            >
              Copiar senha
            </Button>
            <Button onClick={() => setCredenciais(null)}>Fechar</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

export default function Plataforma() {
  const [tab, setTab] = useState('clientes');

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold">Plataforma</h1>
        <p className="text-sm text-muted-foreground">Área do dono do sistema: clientes, catálogos de veículos, administradores e auditoria.</p>
      </div>
      <Tabs value={tab} onValueChange={setTab}>
        <TabsList>
          <TabsTrigger value="clientes">Clientes</TabsTrigger>
          <TabsTrigger value="catalogos">Catálogos</TabsTrigger>
          <TabsTrigger value="administradores">Administradores</TabsTrigger>
          <TabsTrigger value="auditoria">Auditoria</TabsTrigger>
        </TabsList>
        <TabsContent value="clientes" className="mt-4">
          <ClientesTab />
        </TabsContent>
        <TabsContent value="catalogos" className="mt-4">
          <CatalogosTab />
        </TabsContent>
        <TabsContent value="administradores" className="mt-4">
          <AdministradoresTab />
        </TabsContent>
        <TabsContent value="auditoria" className="mt-4">
          <AuditoriaTab />
        </TabsContent>
      </Tabs>
    </div>
  );
}
