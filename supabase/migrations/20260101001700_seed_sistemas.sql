-- Catalogo global de sistemas. O admin-api e as policies buscam o slug 'servicos'; sem a linha, criar cliente falha.
insert into public.sistemas (slug, nome, descricao)
values ('servicos', 'HUB', 'Financeiro + Oficina')
on conflict (slug) do nothing;
