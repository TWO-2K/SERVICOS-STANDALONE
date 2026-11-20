import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Pencil, Plus, Trash2 } from 'lucide-react';

import { adminApi } from '@/shared/api/adminApi';
import {
  Button,
  Dialog,
  DialogContent,
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
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  useToast,
} from '@/shared/ui';

import ConfirmDeleteDialog from '@/components/ConfirmDeleteDialog';

const SEM_VALOR = '__nenhum__';
const cadastrosKey = ['servicos', 'admin-cadastros'];

// Cada tipo descreve seus campos; `ref` aponta para outro cadastro usado como lista de opcoes.
const TIPOS = [
  {
    tipo: 'empresas',
    label: 'Empresas',
    singular: 'empresa',
    campos: [{ name: 'nome', label: 'Nome', required: true }],
    colunas: [{ name: 'nome', label: 'Nome' }],
  },
  {
    tipo: 'unidades',
    label: 'Unidades',
    singular: 'unidade',
    campos: [
      { name: 'nome', label: 'Nome', required: true },
      { name: 'empresa_id', label: 'Empresa', ref: 'empresas' },
      { name: 'cidade', label: 'Cidade' },
      { name: 'endereco', label: 'Endereço' },
      { name: 'telefone', label: 'Telefone' },
      { name: 'responsavel', label: 'Responsável' },
      { name: 'cnpj', label: 'CNPJ' },
    ],
    colunas: [
      { name: 'nome', label: 'Nome' },
      { name: 'empresa_id', label: 'Empresa', ref: 'empresas' },
      { name: 'cidade', label: 'Cidade' },
    ],
  },
  {
    tipo: 'departamentos',
    label: 'Departamentos',
    singular: 'departamento',
    campos: [
      { name: 'nome', label: 'Nome', required: true },
      { name: 'descricao', label: 'Descrição' },
    ],
    colunas: [
      { name: 'nome', label: 'Nome' },
      { name: 'descricao', label: 'Descrição' },
    ],
  },
  {
    tipo: 'cargos',
    label: 'Cargos',
    singular: 'cargo',
    campos: [
      { name: 'nome', label: 'Nome', required: true },
      { name: 'departamento_id', label: 'Departamento', ref: 'departamentos' },
    ],
    colunas: [
      { name: 'nome', label: 'Nome' },
      { name: 'departamento_id', label: 'Departamento', ref: 'departamentos' },
    ],
  },
];

function nomeDe(lista, id) {
  return (lista || []).find((item) => item.id === id)?.nome || '—';
}

function CadastroTab({ config, dados }) {
  const { toast } = useToast();
  const queryClient = useQueryClient();
  const [editando, setEditando] = useState(null); // { id?, ...valores }
  const [excluindo, setExcluindo] = useState(null);
  const rows = dados[config.tipo] || [];

  const refresh = () => queryClient.invalidateQueries({ queryKey: cadastrosKey });

  const salvarMutation = useMutation({
    mutationFn: (valores) => {
      const payload = { ...valores };
      for (const campo of config.campos) {
        if (campo.ref && payload[campo.name] === SEM_VALOR) payload[campo.name] = null;
      }
      return adminApi.cadastros.salvar(config.tipo, payload);
    },
    onSuccess: () => {
      toast({ title: `${config.label.slice(0, -1)} salvo(a)` });
      setEditando(null);
      refresh();
    },
    onError: (error) => toast({ title: 'Não foi possível salvar', description: error.message }),
  });

  const excluirMutation = useMutation({
    mutationFn: (id) => adminApi.cadastros.excluir(config.tipo, id),
    onMutate: (id) => {
      const previous = queryClient.getQueryData(cadastrosKey);
      queryClient.setQueryData(cadastrosKey, (old) => ({
        ...old,
        [config.tipo]: (old?.[config.tipo] || []).filter((item) => item.id !== id),
      }));
      setExcluindo(null);
      return { previous };
    },
    onSuccess: () => {
      toast({ title: 'Registro excluído' });
      refresh();
    },
    onError: (error, _id, context) => {
      if (context?.previous) queryClient.setQueryData(cadastrosKey, context.previous);
      toast({ title: 'Não foi possível excluir', description: error.message });
    },
  });

  function abrirNovo() {
    const inicial = {};
    for (const campo of config.campos) inicial[campo.name] = campo.ref ? SEM_VALOR : '';
    setEditando(inicial);
  }

  function abrirEdicao(row) {
    const valores = { id: row.id };
    for (const campo of config.campos) valores[campo.name] = row[campo.name] ?? (campo.ref ? SEM_VALOR : '');
    setEditando(valores);
  }

  const podeSalvar = editando && config.campos.every((c) => !c.required || String(editando[c.name] || '').trim());

  return (
    <div className="space-y-3">
      <div className="flex justify-end">
        <Button onClick={abrirNovo}>
          <Plus className="mr-1 h-4 w-4" /> Nova {config.singular}
        </Button>
      </div>

      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">Nenhum registro cadastrado.</p>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                {config.colunas.map((coluna) => (
                  <TableHead key={coluna.name}>{coluna.label}</TableHead>
                ))}
                <TableHead className="text-right">Ações</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id}>
                  {config.colunas.map((coluna) => (
                    <TableCell key={coluna.name}>
                      {coluna.ref ? nomeDe(dados[coluna.ref], row[coluna.name]) : row[coluna.name] || '—'}
                    </TableCell>
                  ))}
                  <TableCell className="text-right">
                    <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => abrirEdicao(row)}>
                      <Pencil className="h-4 w-4" />
                    </Button>
                    <Button variant="ghost" size="icon" aria-label="Excluir" onClick={() => setExcluindo(row)}>
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      <Dialog open={Boolean(editando)} onOpenChange={(open) => !open && setEditando(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {editando?.id ? 'Editar' : 'Nova'} {config.singular}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            {config.campos.map((campo) => (
              <div key={campo.name} className="space-y-1">
                <Label htmlFor={`cad-${config.tipo}-${campo.name}`}>{campo.label}</Label>
                {campo.ref ? (
                  <Select
                    value={editando?.[campo.name] || SEM_VALOR}
                    onValueChange={(value) => setEditando({ ...editando, [campo.name]: value })}
                  >
                    <SelectTrigger id={`cad-${config.tipo}-${campo.name}`}>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value={SEM_VALOR}>Nenhum</SelectItem>
                      {(dados[campo.ref] || []).map((item) => (
                        <SelectItem key={item.id} value={item.id}>
                          {item.nome}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                ) : (
                  <Input
                    id={`cad-${config.tipo}-${campo.name}`}
                    value={editando?.[campo.name] || ''}
                    onChange={(e) => setEditando({ ...editando, [campo.name]: e.target.value })}
                  />
                )}
              </div>
            ))}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setEditando(null)}>
              Cancelar
            </Button>
            <Button disabled={!podeSalvar || salvarMutation.isPending} onClick={() => salvarMutation.mutate(editando)}>
              {salvarMutation.isPending ? 'Salvando...' : 'Salvar'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ConfirmDeleteDialog
        open={Boolean(excluindo)}
        onOpenChange={(open) => !open && setExcluindo(null)}
        onConfirm={() => excluirMutation.mutate(excluindo.id)}
        isLoading={excluirMutation.isPending}
        description={`Excluir "${excluindo?.nome || ''}"? Registros que ainda estão em uso não podem ser excluídos.`}
      />
    </div>
  );
}

export default function Cadastros() {
  const [tab, setTab] = useState(TIPOS[0].tipo);
  const query = useQuery({ queryKey: cadastrosKey, queryFn: () => adminApi.cadastros.list() });

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-bold">Cadastros</h2>
        <p className="text-sm text-muted-foreground">
          Empresas, unidades, departamentos e cargos usados nos usuários, solicitações e relatórios.
        </p>
      </div>

      {query.isLoading ? (
        <MoneyLoader inline />
      ) : (
        <Tabs value={tab} onValueChange={setTab}>
          <TabsList>
            {TIPOS.map((config) => (
              <TabsTrigger key={config.tipo} value={config.tipo}>
                {config.label}
              </TabsTrigger>
            ))}
          </TabsList>
          {TIPOS.map((config) => (
            <TabsContent key={config.tipo} value={config.tipo} className="mt-4">
              <CadastroTab config={config} dados={query.data || {}} />
            </TabsContent>
          ))}
        </Tabs>
      )}
    </div>
  );
}
