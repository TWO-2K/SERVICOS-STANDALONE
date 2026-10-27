// Assinatura do colaborador (public.colaboradores.assinatura_path) e' um dado de identidade do cliente.
// O bucket `assinaturas` e' privado: o banco guarda so o caminho do arquivo e as APIs devolvem uma URL
// assinada com validade curta (createSignatureSignedUrl). Qualquer *-api que precise permitir o cadastro/edicao
// dessa assinatura chama este helper com o proprio `sql` (postgres.js) e um client de storage com service role,
// em vez de duplicar o update + limpeza do arquivo anterior em cada Edge Function.
import { toPublicStorageUrl } from './storage-url.ts';

type SqlTag = (query: string, values?: unknown[]) => Promise<Array<Record<string, unknown>>>;

interface StorageClient {
  storage: {
    from(bucket: string): {
      remove(paths: string[]): Promise<{ error: { message: string } | null }>;
      createSignedUrl(
        path: string,
        expiresIn: number,
      ): Promise<{ data: { signedUrl: string } | null; error: { message: string } | null }>;
    };
  };
}

const SIGNATURES_STORAGE_BUCKET = 'assinaturas';
// Validade da URL devolvida ao navegador (a sessao do app guarda o perfil; ao recarregar vem outra).
export const SIGNATURE_URL_TTL_SECONDS = 60 * 60 * 12;

export function isOwnSignaturePath(path: string, collaboratorId: string) {
  return path.startsWith(`colaboradores/${collaboratorId}/`) && !path.includes('..');
}

export async function createSignatureSignedUrl(
  storageClient: StorageClient | null,
  path: string | null | undefined,
  expiresIn = SIGNATURE_URL_TTL_SECONDS,
): Promise<string | null> {
  if (!path || !storageClient) return null;
  const { data, error } = await storageClient.storage.from(SIGNATURES_STORAGE_BUCKET).createSignedUrl(path, expiresIn);
  if (error || !data) {
    console.error('Failed to create signature signed URL:', { path, message: error?.message });
    return null;
  }
  return toPublicStorageUrl(data.signedUrl);
}

export async function updateColaboradorSignature(
  sql: SqlTag,
  storageClient: StorageClient | null,
  collaboratorId: string,
  signaturePath: string,
) {
  const previousRows = await sql(
    `select assinatura_path from public.colaboradores where id = $1 limit 1;`,
    [collaboratorId],
  );

  await sql(
    `
      update public.colaboradores
      set assinatura_url = null,
          assinatura_path = $2,
          atualizado_em = now()
      where id = $1;
    `,
    [collaboratorId, signaturePath],
  );

  const previousPath = previousRows[0]?.assinatura_path as string | null | undefined;
  if (previousPath && previousPath !== signaturePath && storageClient) {
    const { error } = await storageClient.storage.from(SIGNATURES_STORAGE_BUCKET).remove([previousPath]);
    if (error) {
      console.error('Failed to delete previous signature:', { path: previousPath, message: error.message });
    }
  }

  return {
    signaturePath,
    signatureUrl: await createSignatureSignedUrl(storageClient, signaturePath),
  };
}
