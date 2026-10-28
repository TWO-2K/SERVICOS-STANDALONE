-- Lembrete de aprovacoes pendentes passa de hora em hora para uma vez por dia, as 9h de Brasilia (12:00 UTC).
-- O intervalo entre lembretes da mesma solicitacao continua 24h (LEMBRETE_INTERVALO_HORAS na function).
select cron.unschedule(jobname) from cron.job
where jobname in ('servicos-lembrete-aprovacoes-hourly', 'servicos-lembrete-aprovacoes-daily');

select cron.schedule('servicos-lembrete-aprovacoes-daily', '0 12 * * *',
  $job$select plataforma.invocar_function('servicos-lembrete-aprovacoes');$job$);
