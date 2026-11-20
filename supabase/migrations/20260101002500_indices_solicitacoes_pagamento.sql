create index if not exists "idx_servicos_solicitacoes_departamento_id"
  on "public"."solicitacoes_pagamento" using "btree" ("departamento_id");

create index if not exists "idx_servicos_solicitacoes_aprovador_destino_id"
  on "public"."solicitacoes_pagamento" using "btree" ("aprovador_destino_id");

create index if not exists "idx_servicos_solicitacoes_empresa_id"
  on "public"."solicitacoes_pagamento" using "btree" ("empresa_id");

create index if not exists "idx_servicos_solicitacoes_forma_pagamento"
  on "public"."solicitacoes_pagamento" using "btree" ("forma_pagamento")
  where "forma_pagamento" is not null;
