-- Logs de seguranca (gestao_plataforma) nao tem tenant_id e as policies de SELECT liberavam qualquer admin/gestor de
-- qualquer cliente. Nada no frontend le essas tabelas: so as Edge Functions de seguranca gravam (service_role).
-- Remove o acesso de leitura dos usuarios logados para que um cliente nunca veja logs de outro, mesmo que o schema
-- seja exposto no PostgREST no futuro.
revoke select on gestao_plataforma.logs_acesso from authenticated;
revoke select on gestao_plataforma.logs_auditoria from authenticated;
revoke select on gestao_plataforma.alertas_seguranca_enviados from authenticated;

drop policy if exists logs_acesso_plataforma_select_admin_console on gestao_plataforma.logs_acesso;
drop policy if exists logs_auditoria_plataforma_select_admin_console on gestao_plataforma.logs_auditoria;
drop policy if exists alertas_seguranca_enviados_select_admin_console on gestao_plataforma.alertas_seguranca_enviados;
