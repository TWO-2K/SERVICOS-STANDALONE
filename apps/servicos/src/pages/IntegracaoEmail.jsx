import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';

import { adminApi } from '@/shared/api/adminApi';
import { Button, Input, Label, MoneyLoader, Switch, useToast } from '@/shared/ui';

const integracaoKey = ['servicos', 'admin-integracao-gmail'];

function CampoSegredo({ id, label, configurado, value, onChange, disabled }) {
  return (
    <div className="space-y-1">
      <Label htmlFor={id}>{label}</Label>
      <Input
        id={id}
        type="password"
        autoComplete="off"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        disabled={disabled}
        placeholder={configurado ? 'Já configurado — deixe em branco para manter' : ''}
      />
    </div>
  );
}

function Formulario({ dados }) {
  const { toast } = useToast();
  const queryClient = useQueryClient();
  const [form, setForm] = useState({
    sender: dados.sender || '',
    client_id: dados.client_id || '',
    client_secret: '',
    refresh_token: '',
    ativo: dados.configurada ? dados.ativo : true,
  });
  const set = (campo) => (valor) => setForm((atual) => ({ ...atual, [campo]: valor }));

  const salvarMutation = useMutation({
    mutationFn: () => adminApi.integracoes.gmailSalvar(form),
    onSuccess: (resultado) => {
      toast({ title: 'Integração de e-mail salva' });
      queryClient.setQueryData(integracaoKey, resultado);
      setForm((atual) => ({ ...atual, client_secret: '', refresh_token: '' }));
    },
    onError: (error) => toast({ title: 'Não foi possível salvar', description: error.message }),
  });

  const tem = (campo) => dados.segredos?.includes(campo);
  const podeSalvar = form.sender.trim() && form.client_id.trim();

  return (
    <div className="max-w-xl space-y-4 rounded-lg border border-border bg-card p-4">
      <div className="space-y-1">
        <Label htmlFor="gmail-sender">E-mail remetente</Label>
        <Input id="gmail-sender" value={form.sender} onChange={(e) => set('sender')(e.target.value)} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="gmail-client-id">Client ID (Google Cloud)</Label>
        <Input id="gmail-client-id" value={form.client_id} onChange={(e) => set('client_id')(e.target.value)} />
      </div>
      <CampoSegredo
        id="gmail-client-secret"
        label="Client Secret"
        configurado={tem('client_secret')}
        value={form.client_secret}
        onChange={set('client_secret')}
      />
      <CampoSegredo
        id="gmail-refresh-token"
        label="Refresh Token"
        configurado={tem('refresh_token')}
        value={form.refresh_token}
        onChange={set('refresh_token')}
      />
      <label className="flex items-center justify-between gap-4">
        <span className="text-sm">
          Envio ativo
          <span className="block text-xs text-muted-foreground">Desligado, os e-mails ficam parados na fila.</span>
        </span>
        <Switch checked={form.ativo} onCheckedChange={set('ativo')} />
      </label>
      <div className="flex justify-end">
        <Button disabled={!podeSalvar || salvarMutation.isPending} onClick={() => salvarMutation.mutate()}>
          {salvarMutation.isPending ? 'Salvando...' : 'Salvar'}
        </Button>
      </div>
    </div>
  );
}

export default function IntegracaoEmail() {
  const query = useQuery({ queryKey: integracaoKey, queryFn: () => adminApi.integracoes.gmailObter() });

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-xl font-bold">E-mail</h2>
        <p className="text-sm text-muted-foreground">
          Conta Gmail usada para enviar os e-mails desta empresa. Os segredos ficam guardados de forma criptografada e
          não são exibidos depois de salvos.
        </p>
      </div>
      {query.isLoading ? <MoneyLoader inline /> : query.data ? <Formulario dados={query.data} /> : null}
    </div>
  );
}
