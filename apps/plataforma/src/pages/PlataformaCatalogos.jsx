import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Pencil, Plus, Trash2 } from 'lucide-react';

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
  Spinner,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
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

import { normalize } from '@/lib/normalize';

const catalogoKey = ['servicos', 'admin-plataforma-catalogo'];
const auditoriaKey = ['servicos', 'admin-plataforma-auditoria'];

const TIPOS = {
  marcas: { titulo: 'Marcas', singular: 'marca', temAtivo: true },
  modelos: { titulo: 'Modelos', singular: 'modelo', temAtivo: true },
  categorias: { titulo: 'Categorias', singular: 'categoria', temAtivo: true },
  cores: { titulo: 'Cores', singular: 'cor', temAtivo: false },
};

const FORM_VAZIO = { id: null, nome: '', ativo: true, marca_id: '', categoria_veiculo_id: '' };

function CatalogoTabela({ tipo, dados }) {
  const { toast } = useToast();
  const queryClient = useQueryClient();
  const config = TIPOS[tipo];
  const [busca, setBusca] = useState('');
  const [form, setForm] = useState(null);
  const [excluir, setExcluir] = useState(null);

  const linhas = (dados[tipo] || []).filter((row) => {
    const termo = normalize(busca);
    return !termo || [row.nome, row.marca_nome, row.categoria_nome].some((v) => normalize(v).includes(termo));
  });

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: catalogoKey });
    queryClient.invalidateQueries({ queryKey: auditoriaKey });
  };

  const salvarMutation = useMutation({
    mutationFn: (dadosForm) =>
      adminApi.plataforma.catalogo.salvar({
        tipo,
        id: dadosForm.id || undefined,
        nome: dadosForm.nome,
        ...(config.temAtivo ? { ativo: dadosForm.ativo } : {}),
        ...(tipo === 'modelos'
          ? { marca_id: dadosForm.marca_id, categoria_veiculo_id: dadosForm.categoria_veiculo_id }
          : {}),
      }),
    onSuccess: () => {
      toast({ title: 'Salvo' });
      setForm(null);
      refresh();
    },
    onError: (error) => toast({ title: 'Não foi possível salvar', description: error.message }),
  });

  const alternarAtivo = useMutation({
    mutationFn: (row) =>
      adminApi.plataforma.catalogo.salvar({
        tipo,
        id: row.id,
        nome: row.nome,
        ativo: !row.ativo,
        ...(tipo === 'modelos' ? { marca_id: row.marca_id, categoria_veiculo_id: row.categoria_veiculo_id } : {}),
      }),
    onSuccess: refresh,
    onError: (error) => toast({ title: 'Não foi possível alterar', description: error.message }),
  });

  const excluirMutation = useMutation({
    mutationFn: (row) => adminApi.plataforma.catalogo.excluir(tipo, row.id),
    onSuccess: () => {
      toast({ title: 'Excluído' });
      setExcluir(null);
      refresh();
    },
    onError: (error) => {
      setExcluir(null);
      toast({ title: 'Não foi possível excluir', description: error.message });
    },
  });

  const podeSalvar =
    form &&
    form.nome.trim() &&
    (tipo !== 'modelos' || (form.marca_id && form.categoria_veiculo_id)) &&
    !salvarMutation.isPending;

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <Input
          className="max-w-xs"
          placeholder={`Buscar ${config.titulo.toLowerCase()}`}
          value={busca}
          onChange={(e) => setBusca(e.target.value)}
        />
        <Button onClick={() => setForm({ ...FORM_VAZIO })}>
          <Plus className="mr-1 h-4 w-4" /> Nova {config.singular}
        </Button>
      </div>

      <div className="overflow-x-auto rounded-lg border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Nome</TableHead>
              {tipo === 'modelos' && <TableHead>Marca</TableHead>}
              {tipo === 'modelos' && <TableHead>Categoria</TableHead>}
              {tipo === 'marcas' && <TableHead>Modelos</TableHead>}
              {tipo === 'modelos' && <TableHead>Veículos</TableHead>}
              {config.temAtivo && <TableHead>Situação</TableHead>}
              <TableHead className="text-right">Ações</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {linhas.length === 0 && (
              <TableRow>
                <TableCell colSpan={6} className="text-center text-sm text-muted-foreground">
                  Nenhum item.
                </TableCell>
              </TableRow>
            )}
            {linhas.map((row) => (
              <TableRow key={row.id}>
                <TableCell className="font-medium">{row.nome}</TableCell>
                {tipo === 'modelos' && <TableCell>{row.marca_nome}</TableCell>}
                {tipo === 'modelos' && <TableCell>{row.categoria_nome}</TableCell>}
                {tipo === 'marcas' && <TableCell>{row.modelos}</TableCell>}
                {tipo === 'modelos' && <TableCell>{row.veiculos}</TableCell>}
                {config.temAtivo && (
                  <TableCell>
                    <div className="flex items-center gap-2">
                      <Switch
                        checked={row.ativo}
                        disabled={alternarAtivo.isPending}
                        onCheckedChange={() => alternarAtivo.mutate(row)}
                        aria-label={row.ativo ? 'Desativar' : 'Ativar'}
                      />
                      <Badge variant={row.ativo ? 'default' : 'secondary'}>{row.ativo ? 'Ativo' : 'Inativo'}</Badge>
                    </div>
                  </TableCell>
                )}
                <TableCell className="text-right">
                  <Button
                    variant="ghost"
                    size="icon"
                    aria-label="Editar"
                    onClick={() =>
                      setForm({
                        id: row.id,
                        nome: row.nome,
                        ativo: row.ativo ?? true,
                        marca_id: row.marca_id || '',
                        categoria_veiculo_id: row.categoria_veiculo_id || '',
                      })
                    }
                  >
                    <Pencil className="h-4 w-4" />
                  </Button>
                  <Button variant="ghost" size="icon" aria-label="Excluir" onClick={() => setExcluir(row)}>
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      <Dialog open={Boolean(form)} onOpenChange={(open) => !open && setForm(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {form?.id ? 'Editar' : 'Nova'} {config.singular}
            </DialogTitle>
            <DialogDescription>Vale para todos os clientes.</DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1">
              <Label htmlFor="catalogo-nome">Nome</Label>
              <Input
                id="catalogo-nome"
                value={form?.nome || ''}
                onChange={(e) => setForm((f) => ({ ...f, nome: e.target.value }))}
              />
            </div>
            {tipo === 'modelos' && (
              <>
                <div className="space-y-1">
                  <Label>Marca</Label>
                  <Select value={form?.marca_id || ''} onValueChange={(v) => setForm((f) => ({ ...f, marca_id: v }))}>
                    <SelectTrigger aria-label="Marca">
                      <SelectValue placeholder="Selecione a marca" />
                    </SelectTrigger>
                    <SelectContent>
                      {(dados.marcas || []).map((m) => (
                        <SelectItem key={m.id} value={m.id}>
                          {m.nome}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1">
                  <Label>Categoria</Label>
                  <Select
                    value={form?.categoria_veiculo_id || ''}
                    onValueChange={(v) => setForm((f) => ({ ...f, categoria_veiculo_id: v }))}
                  >
                    <SelectTrigger aria-label="Categoria">
                      <SelectValue placeholder="Selecione a categoria" />
                    </SelectTrigger>
                    <SelectContent>
                      {(dados.categorias || []).map((c) => (
                        <SelectItem key={c.id} value={c.id}>
                          {c.nome}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </>
            )}
            {config.temAtivo && (
              <div className="flex items-center gap-2">
                <Switch checked={Boolean(form?.ativo)} onCheckedChange={(v) => setForm((f) => ({ ...f, ativo: v }))} />
                <span className="text-sm">Ativo (aparece nas listas de cadastro de veículo)</span>
              </div>
            )}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setForm(null)}>
              Cancelar
            </Button>
            <Button disabled={!podeSalvar} onClick={() => salvarMutation.mutate(form)}>
              {salvarMutation.isPending ? 'Salvando...' : 'Salvar'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(excluir)} onOpenChange={(open) => !open && setExcluir(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Excluir {config.singular}</DialogTitle>
            <DialogDescription>
              {excluir?.nome} será removido para todos os clientes. Se estiver em uso, a exclusão é recusada
              {config.temAtivo ? '; nesse caso, desative.' : '.'}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setExcluir(null)}>
              Cancelar
            </Button>
            <Button disabled={excluirMutation.isPending} onClick={() => excluirMutation.mutate(excluir)}>
              Excluir
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

export function CatalogosTab() {
  const query = useQuery({ queryKey: catalogoKey, queryFn: () => adminApi.plataforma.catalogo.list() });

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-bold">Catálogos de veículos</h2>
        <p className="text-sm text-muted-foreground">
          Marcas, modelos, categorias e cores compartilhadas por todos os clientes. Itens inativos somem das listas de
          cadastro, mas os veículos já cadastrados continuam válidos.
        </p>
      </div>
      {query.isLoading || !query.data ? (
        <div className="flex items-center justify-center py-12">
          <Spinner size="lg" />
        </div>
      ) : (
        <Tabs defaultValue="marcas">
          <TabsList>
            {Object.entries(TIPOS).map(([tipo, cfg]) => (
              <TabsTrigger key={tipo} value={tipo}>
                {cfg.titulo}
              </TabsTrigger>
            ))}
          </TabsList>
          {Object.keys(TIPOS).map((tipo) => (
            <TabsContent key={tipo} value={tipo} className="mt-4">
              <CatalogoTabela tipo={tipo} dados={query.data} />
            </TabsContent>
          ))}
        </Tabs>
      )}
    </div>
  );
}
