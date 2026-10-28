// Chave publica VAPID -- e publica por design (vai no bundle do front sem problema), a privada
// fica so no Supabase (secret VAPID_PRIVATE_KEY, usada em supabase/functions/_shared/push.ts).
// Se um dia rotacionar as chaves, atualizar aqui E no secret do Supabase juntos.
export const VAPID_PUBLIC_KEY =
  'BC2gu-TimW7PR7Qltr80gd8icbOzIYGkNj5Wr0VIKF-qscbAtYFIr6HmeYg-e1Os9kr2l0aTZEI1xFM3g6c3WfY';

export const PUSH_SW_URL = '/push-sw.js';
