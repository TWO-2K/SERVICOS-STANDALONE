import { useEffect, useState } from 'react';
import { useMutation, useQuery } from '@tanstack/react-query';

import { adminApi } from '@/shared/api/adminApi';
import {
  BrandForm,
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
  useToast,
} from '@/shared/ui';

// Endereco publico do app dos clientes (cada cliente abre em APP_URL/slug).
const APP_URL = (import.meta.env.VITE_APP_URL || 'http://localhost:5177').replace(/\/$/, '');

export function EditarClienteDialog({ cliente, onClose, onSalvo }) {
  const { toast } = useToast();
  const [nome, setNome] = useState('');
  const [plano, setPlano] = useState('');

  useEffect(() => {
    setNome(cliente?.nome || '');
    setPlano(cliente?.plano || '');
  }, [cliente]);

  const salvarMutation = useMutation({
    mutationFn: () => adminApi.tenants.atualizar(cliente.id, { nome: nome.trim(), plano: plano.trim() }),
    onSuccess: () => {
      toast({ title: 'Cliente atualizado' });
      onSalvo();
      onClose();
    },
    onError: (error) => toast({ title: 'Não foi possível salvar', description: error.message }),
  });

  return (
    <Dialog open={Boolean(cliente)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Editar cliente</DialogTitle>
          <DialogDescription>O identificador (slug) não muda depois de criado.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <div className="space-y-1">
            <Label htmlFor="cliente-edit-nome">Nome</Label>
            <Input id="cliente-edit-nome" value={nome} onChange={(e) => setNome(e.target.value)} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="cliente-edit-plano">Plano</Label>
            <Input id="cliente-edit-plano" value={plano} onChange={(e) => setPlano(e.target.value)} />
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancelar
          </Button>
          <Button disabled={!nome.trim() || !plano.trim() || salvarMutation.isPending} onClick={() => salvarMutation.mutate()}>
            {salvarMutation.isPending ? 'Salvando...' : 'Salvar'}
          </Button>
        </DialogFooter>
        {cliente ? (
          <div className="space-y-3 border-t pt-4">
            <div>
              <div className="text-sm font-medium">Identidade visual</div>
              <p className="text-xs text-muted-foreground">
                Endereço de acesso: <span className="select-all font-mono">{`${APP_URL}/${cliente.slug}`}</span>
              </p>
            </div>
            <BrandForm
              key={cliente.id}
              marca={{
                nome: cliente.marca_nome,
                cor: cliente.marca_cor,
                logo_url: cliente.marca_logo_url,
                fundo_url: cliente.marca_fundo_url,
                nome_cliente: cliente.nome,
              }}
              onSave={async (payload) => {
                await adminApi.tenants.salvarMarca(cliente.id, payload);
                toast({ title: 'Identidade visual atualizada' });
                onSalvo();
              }}
            />
          </div>
        ) : null}
      </DialogContent>
    </Dialog>
  );
}

export function NovoAdminDialog({ cliente, onClose, onCriado }) {
  const { toast } = useToast();
  const [nome, setNome] = useState('');
  const [email, setEmail] = useState('');
  const [resultado, setResultado] = useState(null);

  useEffect(() => {
    setNome('');
    setEmail('');
    setResultado(null);
  }, [cliente]);

  const criarMutation = useMutation({
    mutationFn: () => adminApi.tenants.criarAdmin(cliente.id, { nome: nome.trim(), email: email.trim() }),
    onSuccess: ({ row }) => {
      setResultado({ email: row.email, senha: row.senha_temporaria, emailEnviado: row.email_enviado });
      onCriado?.();
    },
    onError: (error) => toast({ title: 'Não foi possível criar o administrador', description: error.message }),
  });

  return (
    <Dialog open={Boolean(cliente)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Novo administrador</DialogTitle>
          <DialogDescription>
            {resultado
              ? resultado.emailEnviado
                ? `Enviamos o acesso para ${resultado.email}. A senha precisa ser trocada no primeiro acesso.`
                : 'Envie os dados abaixo ao administrador. A senha não será exibida novamente e precisa ser trocada no primeiro acesso.'
              : `Cria um usuário administrador em ${cliente?.nome || ''}. Use um e-mail que ainda não tenha conta.`}
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
              <Label htmlFor="novo-admin-nome">Nome</Label>
              <Input id="novo-admin-nome" value={nome} onChange={(e) => setNome(e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="novo-admin-email">E-mail</Label>
              <Input id="novo-admin-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>
          </div>
        )}

        <DialogFooter>
          {resultado ? null : (
            <Button disabled={criarMutation.isPending || !nome.trim() || !email.trim()} onClick={() => criarMutation.mutate()}>
              {criarMutation.isPending ? 'Criando...' : 'Criar administrador'}
            </Button>
          )}
          <Button variant="outline" onClick={onClose}>
            Fechar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function RedefinirSenhaAdminDialog({ cliente, onClose }) {
  const { toast } = useToast();
  const [resultado, setResultado] = useState(null);

  useEffect(() => {
    setResultado(null);
  }, [cliente]);

  const adminsQuery = useQuery({
    queryKey: ['servicos', 'admin-tenant-admins', cliente?.id],
    queryFn: () => adminApi.tenants.admins(cliente.id),
    enabled: Boolean(cliente),
  });

  const resetarMutation = useMutation({
    mutationFn: (admin) => adminApi.tenants.resetarSenhaAdmin(cliente.id, admin.id),
    onSuccess: (result, admin) =>
      setResultado({ email: admin.email, senha: result.senha_temporaria, emailEnviado: result.email_enviado }),
    onError: (error) => toast({ title: 'Não foi possível redefinir a senha', description: error.message }),
  });

  return (
    <Dialog open={Boolean(cliente)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Redefinir senha de administrador</DialogTitle>
          <DialogDescription>
            {resultado
              ? resultado.emailEnviado
                ? `Enviamos o acesso para ${resultado.email}. A senha precisa ser trocada no primeiro acesso.`
                : 'Envie os dados abaixo ao administrador. A senha não será exibida novamente e precisa ser trocada no primeiro acesso.'
              : `Escolha o administrador de ${cliente?.nome || ''}. Uma senha temporária será gerada.`}
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
        ) : adminsQuery.isLoading ? (
          <div className="flex items-center justify-center py-6">
            <Spinner />
          </div>
        ) : (adminsQuery.data || []).length === 0 ? (
          <p className="text-sm text-muted-foreground">Este cliente não tem administradores.</p>
        ) : (
          <div className="divide-y divide-border rounded-md border border-border">
            {adminsQuery.data.map((admin) => (
              <div key={admin.id} className="flex items-center justify-between gap-3 px-3 py-2">
                <div className="min-w-0">
                  <div className="truncate text-sm font-medium">{admin.nome}</div>
                  <div className="truncate text-xs text-muted-foreground">{admin.email}</div>
                </div>
                <Button size="sm" variant="outline" disabled={resetarMutation.isPending} onClick={() => resetarMutation.mutate(admin)}>
                  Redefinir
                </Button>
              </div>
            ))}
          </div>
        )}

        <DialogFooter>
          {resultado && !resultado.emailEnviado ? (
            <Button
              variant="outline"
              onClick={() => navigator.clipboard?.writeText(resultado.senha).then(() => toast({ title: 'Senha copiada' }))}
            >
              Copiar senha
            </Button>
          ) : null}
          <Button onClick={onClose}>Fechar</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function ExcluirClienteDialog({ cliente, onClose, onExcluido }) {
  const { toast } = useToast();
  const [slug, setSlug] = useState('');

  useEffect(() => {
    setSlug('');
  }, [cliente]);

  const excluirMutation = useMutation({
    mutationFn: () => adminApi.tenants.excluir(cliente.id, slug.trim()),
    onSuccess: (result) => {
      const falhas = result.falhas || [];
      toast({
        title: 'Cliente excluído',
        description: falhas.length ? `Não foi possível limpar: ${falhas.join(', ')}.` : undefined,
      });
      onExcluido();
      onClose();
    },
    onError: (error) => toast({ title: 'Não foi possível excluir o cliente', description: error.message }),
  });

  const confirmado = Boolean(cliente) && slug.trim().toLowerCase() === cliente.slug.toLowerCase();

  return (
    <Dialog open={Boolean(cliente)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Excluir cliente</DialogTitle>
          <DialogDescription>
            Apaga definitivamente {cliente?.nome || ''} e tudo dele: dados, usuários, anexos e fotos. Não há como desfazer.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-1">
          <Label htmlFor="excluir-slug">Digite o identificador ({cliente?.slug}) para confirmar</Label>
          <Input id="excluir-slug" value={slug} onChange={(e) => setSlug(e.target.value)} autoComplete="off" />
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancelar
          </Button>
          <Button variant="destructive" disabled={!confirmado || excluirMutation.isPending} onClick={() => excluirMutation.mutate()}>
            Excluir definitivamente
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
