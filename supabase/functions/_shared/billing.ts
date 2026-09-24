/**
 * Regras de cobrança resolvidas no servidor — ponto único.
 *
 * Só existe assinatura mensal. Preço e período de teste são configuração de
 * ambiente, nunca literais no código: mudar valor ou trial não pode exigir
 * deploy de function nem release do app.
 *
 * Secrets obrigatórios (supabase secrets set ...):
 *   STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PRICE_MONTHLY
 * Opcionais:
 *   STRIPE_TRIAL_DAYS      (default 0: o teste de 15 dias começa no cadastro,
 *                           migration-22, e assinar cobra na hora)
 *   CHECKOUT_SUCCESS_URL, CHECKOUT_CANCEL_URL  (quando houver domínio próprio)
 */

import { errorResponse } from "./response.ts";

const publicUrl = Deno.env.get("SUPABASE_PUBLIC_URL") ?? Deno.env.get("SUPABASE_URL");
const returnPage = `${publicUrl}/functions/v1/checkout-return`;

export const SUCCESS_URL = Deno.env.get("CHECKOUT_SUCCESS_URL") ?? `${returnPage}?status=sucesso`;
export const CANCEL_URL = Deno.env.get("CHECKOUT_CANCEL_URL") ?? `${returnPage}?status=cancelado`;

/** Volta do portal de cobrança: pode ser assinatura, troca de cartão ou cancelamento. */
export const PORTAL_RETURN_URL = `${returnPage}?status=portal`;

/** Erro cuja mensagem pode ser mostrada ao usuário. */
export class BillingError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
    this.name = "BillingError";
  }
}

const DEFAULT_TRIAL_DAYS = 0;

/**
 * Dias de teste do checkout. Um valor inválido no secret cairia silenciosamente
 * em `NaN` e o Stripe recusaria a sessão inteira, então aqui o valor quebrado é
 * ignorado (com log) e vale o default — melhor abrir o checkout com o teste
 * padrão do que deixar de vender.
 */
export function trialPeriodDays(): number {
  const raw = Deno.env.get("STRIPE_TRIAL_DAYS");
  if (raw === undefined || raw.trim() === "") return DEFAULT_TRIAL_DAYS;

  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 730) {
    console.error(`[billing] STRIPE_TRIAL_DAYS inválido (${raw}); usando ${DEFAULT_TRIAL_DAYS}`);
    return DEFAULT_TRIAL_DAYS;
  }
  return parsed;
}

/**
 * Price ID da assinatura mensal.
 *
 * `plan` só existe para o app que ainda manda o campo: qualquer valor diferente
 * de "monthly" é recusado com mensagem própria em vez de virar uma cobrança
 * mensal disfarçada de outro plano.
 */
export function monthlyPriceId(plan?: string): string {
  if (plan !== undefined && plan !== "monthly") {
    throw new BillingError("No momento a assinatura é apenas mensal.");
  }

  const priceId = Deno.env.get("STRIPE_PRICE_MONTHLY");
  if (!priceId) throw new BillingError("Plano indisponível no momento. Tente novamente mais tarde.");
  return priceId;
}

/**
 * O app mostra `error` em um Alert, então devolver err.message cru vazaria a
 * resposta do provedor — uma StripeError carrega o modo da conta, o prefixo
 * da chave e URLs internas do dashboard. Só mensagem nossa sai daqui; o
 * detalhe fica no log da function.
 */
export function handleBillingError(err: unknown, contexto: string): Response {
  if (err instanceof BillingError) return errorResponse(err.message, err.status);
  if (err instanceof Error && err.message === "Unauthorized") {
    return errorResponse("Não autorizado", 401);
  }
  if (err instanceof Error && err.name === "ZodError") {
    return errorResponse("Dados inválidos.", 400);
  }

  console.error(`[${contexto}]`, err instanceof Error ? err.message : err);
  return errorResponse("Não foi possível concluir a operação de pagamento. Tente novamente em instantes.", 502);
}
