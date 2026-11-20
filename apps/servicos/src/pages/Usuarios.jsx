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
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  useToast,
} from '@/shared/ui';

import Pagination from '@/components/Pagination';
import SearchInput from '@/components/SearchInput';
import { usePagination } from '@/hooks/usePagination';
import { normalize } from '@/lib/normalize';
import { useAuth } from '@/lib/AuthContext';

const NIVEIS = [
  { value: 'usuario', label: 'Usuário' },
  { value: 'gestor', label: 'Gestor' },
  { value: 'admin', label: 'Administrador' },
];
const STATUS = [
  { value: 'ativo', label: 'Ativo' },
  { value: 'inativo', label: 'Inativo' },
  { value: 'afastado', label: 'Afastado' },
];
const SEM_VALOR = '__nenhum__';
const usuariosKey = ['servicos', 'admin-usuarios'];
const FORM_VAZIO = {
  nome: '',
  email: '',
  nivel_acesso: 'usuario',
  departamento_id: SEM_VALOR,
  unidade_id: SEM_VALOR,
  empresa_id: SEM_VALOR,
};

function orNull(value) {
  return value === SEM_VALOR || !value ? null : value;
}

function SelectCatalogo({ value, onChange, itens, placeholder }) {
  return (
    <Select value={value} onValueChange={onChange}>
      <SelectTrigger>
        <SelectValue placeholder={placeholder} />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value={SEM_VALOR}>Nenhum</SelectItem>
        {itens.map((item) => (
          <SelectItem key={item.id} value={item.id}>
            {item.nome}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

function SenhaTemporariaDialog({ dados, onClose }) {
  const { toast } = useToast();
  return (
    <Dialog open={Boolean(dados)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{dados?.emailEnviado ? 'Acesso enviado por e-mail' : 'Senha temporária'}</DialogTitle>
          <DialogDescription>
            {dados?.emailEnviado
              ? `Enviamos o acesso para ${dados?.email}. A senha precisa ser trocada no primeiro login.`
              : 'Copie agora e envie ao usuário. Ela não será exibida novamente.'}
          </DialogDescription>
        </DialogHeader>
        {!dados?.emailEnviado && (
          <div className="space-y-1 rounded-md border bg-muted p-3 text-sm">
            <div>
              <span className="text-muted-foreground">E-mail:</span> {dados?.email}
            </div>
            <div>
              <span className="text-muted-foreground">Senha:</span>{' '}
              <code className="select-all font-mono">{dados?.senha}</code>
            </div>
          </div>
        )}
        <DialogFooter>
          {!dados?.emailEnviado && (
            <Button
              variant="outline"
              onClick={() =>
                navigator.clipboard?.writeText(dados?.senha || '').then(() => toast({ title: 'Senha copiada' }))
              }
            >
              Copiar senha
            </Button>
          )}
          <Button onClick={onClose}>Fechar</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export default function Usuarios() {
  const { toast } = useToast();
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const [busca, setBusca] = useState('');
  const [criarAberto, setCriarAberto] = useState(false);
  const [form, setForm] = useState(FORM_VAZIO);
  const [senhaGerada, setSenhaGerada] = useState(null);
  const [edicao, setEdicao] = useState(null);

  const query = useQuery({ queryKey: usuariosKey, queryFn: () => adminApi.usuarios.list() });
  const rows = query.data?.rows || [];
  const filtrados = rows.filter((row) => {
    const termo = normalize(busca);
    return !termo || [row.nome, row.email].some((value) => normalize(value).includes(termo));
  });
  const { page, setPage, pageItems, total } = usePagination(filtrados, 10);

  const refresh = () => queryClient.invalidateQueries({ queryKey: usuariosKey });

  const criarMutation = useMutation({
    mutationFn: () =>
      adminApi.usuarios.criar({
        nome: form.nome,
        email: form.email,
        nivel_acesso: form.nivel_acesso,
        departamento_id: orNull(form.departamento_id),
        unidade_id: orNull(form.unidade_id),
        empresa_id: orNull(form.empresa_id),
      }),
    onSuccess: (row) => {
      setCriarAberto(false);
      setSenhaGerada({ email: row.email, senha: row.senha_temporaria, emailEnviado: row.email_enviado });
      setForm(FORM_VAZIO);
      refresh();
    },
    onError: (error) => toast({ title: 'Não foi possível criar o usuário', description: error.message }),
  });

  const atualizarMutation = useMutation({
    mutationFn: ({ id, dados }) => adminApi.usuarios.atualizar(id, dados),
    onMutate: ({ id, dados }) => {
      const previous = queryClient.getQueryData(usuariosKey);
      queryClient.setQueryData(usuariosKey, (old) => ({
        ...old,
        rows: (old?.rows || []).map((row) => (row.id === id ? { ...row, ...dados } : row)),
      }));
      return { previous };
    },
    onSuccess: () => {
      toast({ title: 'Usuário atualizado' });
      refresh();
    },
    onError: (error, _variables, context) => {
      if (context?.previous) queryClient.setQueryData(usuariosKey, context.previous);
      toast({ title: 'Não foi possível atualizar o usuário', description: error.message });
    },
  });

  const editarMutation = useMutation({
    mutationFn: ({ id, nome, empresa_id, unidade_id, departamento_id }) =>
      adminApi.usuarios.atualizar(id, {
        nome,
        empresa_id: orNull(empresa_id),
        unidade_id: orNull(unidade_id),
        departamento_id: orNull(departamento_id),
      }),
    onSuccess: () => {
      toast({ title: 'Usuário atualizado' });
      setEdicao(null);
      refresh();
    },
    onError: (error) => toast({ title: 'Não foi possível atualizar o usuário', description: error.message }),
  });

  function abrirEdicao(row) {
    setEdicao({
      id: row.id,
      nome: row.nome,
      email: row.email,
      empresa_id: row.empresa_id || SEM_VALOR,
      unidade_id: row.unidade_id || SEM_VALOR,
      departamento_id: row.departamento_id || SEM_VALOR,
    });
  }

  const resetarMutation = useMutation({
    mutationFn: (row) =>
      adminApi.usuarios
        .resetarSenha(row.id)
        .then((result) => ({ email: row.email, senha: result.senha_temporaria, emailEnviado: result.email_enviado })),
    onSuccess: (resultado) => {
      setSenhaGerada(resultado);
      refresh();
    },
    onError: (error) => toast({ title: 'Não foi possível redefinir a senha', description: error.message }),
  });

  const podeSalvar = form.nome.trim() && form.email.trim() && !criarMutation.isPending;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-xl font-bold">Usuários</h2>
          <p className="text-sm text-muted-foreground">
            Crie logins, defina o nível de acesso e redefina senhas. A senha temporária aparece uma única vez. Os papéis
            por módulo ficam na aba Permissões.
          </p>
        </div>
        <Button onClick={() => setCriarAberto(true)}>
          <Plus className="mr-1 h-4 w-4" /> Novo usuário
        </Button>
      </div>

      <SearchInput value={busca} onChange={setBusca} placeholder="Buscar..." className="max-w-sm" />

      {query.isLoading ? (
        <MoneyLoader inline />
      ) : filtrados.length === 0 ? (
        <p className="text-sm text-muted-foreground">Nenhum usuário encontrado.</p>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Usuário</TableHead>
                <TableHead>Nível de acesso</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Ações</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {pageItems.map((row) => {
                const ehVoce = row.id === user?.id;
                return (
                  <TableRow key={row.id}>
                    <TableCell>
                      <div className="font-medium">
                        {row.nome} {ehVoce && <span className="text-xs text-muted-foreground">(você)</span>}
                      </div>
                      <div className="text-xs text-muted-foreground">{row.email}</div>
                      {row.precisa_trocar_senha && (
                        <Badge variant="outline" className="mt-1">
                          Senha temporária
                        </Badge>
                      )}
                    </TableCell>
                    <TableCell className="max-w-[180px]">
                      <Select
                        value={row.nivel_acesso || 'usuario'}
                        disabled={ehVoce || atualizarMutation.isPending}
                        onValueChange={(value) =>
                          atualizarMutation.mutate({ id: row.id, dados: { nivel_acesso: value } })
                        }
                      >
                        <SelectTrigger>
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          {NIVEIS.map((nivel) => (
                            <SelectItem key={nivel.value} value={nivel.value}>
                              {nivel.label}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </TableCell>
                    <TableCell className="max-w-[160px]">
                      <Select
                        value={row.status}
                        disabled={ehVoce || atualizarMutation.isPending}
                        onValueChange={(value) => atualizarMutation.mutate({ id: row.id, dados: { status: value } })}
                      >
                        <SelectTrigger>
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          {STATUS.map((status) => (
                            <SelectItem key={status.value} value={status.value}>
                              {status.label}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </TableCell>
                    <TableCell className="text-right">
                      <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => abrirEdicao(row)}>
                        <Pencil className="h-4 w-4" />
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        disabled={resetarMutation.isPending}
                        onClick={() => resetarMutation.mutate(row)}
                      >
                        <KeyRound className="mr-1 h-4 w-4" /> Redefinir senha
                      </Button>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}

      {filtrados.length > 0 && (
        <Pagination page={page} pageSize={10} total={total} onPageChange={setPage} itemLabel="usuário(s)" />
      )}

      <Dialog open={criarAberto} onOpenChange={setCriarAberto}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Novo usuário</DialogTitle>
            <DialogDescription>O usuário entra com uma senha temporária e troca no primeiro acesso.</DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1">
              <Label htmlFor="usuario-nome">Nome</Label>
              <Input id="usuario-nome" value={form.nome} onChange={(e) => setForm({ ...form, nome: e.target.value })} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="usuario-email">E-mail</Label>
              <Input
                id="usuario-email"
                type="email"
                value={form.email}
                onChange={(e) => setForm({ ...form, email: e.target.value })}
              />
            </div>
            <div className="space-y-1">
              <Label>Nível de acesso</Label>
              <Select value={form.nivel_acesso} onValueChange={(value) => setForm({ ...form, nivel_acesso: value })}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {NIVEIS.map((nivel) => (
                    <SelectItem key={nivel.value} value={nivel.value}>
                      {nivel.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1">
              <Label>Empresa</Label>
              <SelectCatalogo
                value={form.empresa_id}
                onChange={(value) => setForm({ ...form, empresa_id: value })}
                itens={query.data?.empresas || []}
                placeholder="Empresa"
              />
            </div>
            <div className="space-y-1">
              <Label>Unidade</Label>
              <SelectCatalogo
                value={form.unidade_id}
                onChange={(value) => setForm({ ...form, unidade_id: value })}
                itens={query.data?.unidades || []}
                placeholder="Unidade"
              />
            </div>
            <div className="space-y-1">
              <Label>Departamento</Label>
              <SelectCatalogo
                value={form.departamento_id}
                onChange={(value) => setForm({ ...form, departamento_id: value })}
                itens={query.data?.departamentos || []}
                placeholder="Departamento"
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCriarAberto(false)}>
              Cancelar
            </Button>
            <Button disabled={!podeSalvar} onClick={() => criarMutation.mutate()}>
              {criarMutation.isPending ? 'Criando...' : 'Criar usuário'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(edicao)} onOpenChange={(open) => !open && setEdicao(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Editar usuário</DialogTitle>
            <DialogDescription>{edicao?.email}</DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1">
              <Label htmlFor="usuario-edit-nome">Nome</Label>
              <Input
                id="usuario-edit-nome"
                value={edicao?.nome || ''}
                onChange={(e) => setEdicao({ ...edicao, nome: e.target.value })}
              />
            </div>
            <div className="space-y-1">
              <Label>Empresa</Label>
              <SelectCatalogo
                value={edicao?.empresa_id || SEM_VALOR}
                onChange={(value) => setEdicao({ ...edicao, empresa_id: value })}
                itens={query.data?.empresas || []}
                placeholder="Empresa"
              />
            </div>
            <div className="space-y-1">
              <Label>Unidade</Label>
              <SelectCatalogo
                value={edicao?.unidade_id || SEM_VALOR}
                onChange={(value) => setEdicao({ ...edicao, unidade_id: value })}
                itens={query.data?.unidades || []}
                placeholder="Unidade"
              />
            </div>
            <div className="space-y-1">
              <Label>Departamento</Label>
              <SelectCatalogo
                value={edicao?.departamento_id || SEM_VALOR}
                onChange={(value) => setEdicao({ ...edicao, departamento_id: value })}
                itens={query.data?.departamentos || []}
                placeholder="Departamento"
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setEdicao(null)}>
              Cancelar
            </Button>
            <Button
              disabled={!edicao?.nome?.trim() || editarMutation.isPending}
              onClick={() => editarMutation.mutate(edicao)}
            >
              {editarMutation.isPending ? 'Salvando...' : 'Salvar'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <SenhaTemporariaDialog dados={senhaGerada} onClose={() => setSenhaGerada(null)} />
    </div>
  );
}
