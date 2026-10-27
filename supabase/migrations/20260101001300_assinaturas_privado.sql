-- Bucket `assinaturas` passa a privado: a imagem so abre por URL assinada, gerada pelas APIs a partir de
-- colaboradores.assinatura_path. As URLs publicas antigas deixam de existir, entao assinatura_url e' zerada.
update storage.buckets set public = false where id = 'assinaturas';
update public.colaboradores set assinatura_url = null where assinatura_url is not null;
