/**
 * Contratto comune per i provider di link di pagamento (Revolut, e in futuro PayPal/Stripe).
 *
 * Perché un'interfaccia (Strategy pattern): il chiamante (dispatcher, Queueable, job di
 * retry) non deve mai conoscere i dettagli della singola API esterna. Riceve una richiesta
 * "neutra" (PaymentLinkRequest) e restituisce un esito altrettanto neutro (PaymentLinkResult),
 * qualunque sia il gateway. Aggiungere PayPal o Stripe in futuro significherà solo scrivere
 * una nuova classe che implementa questa interfaccia, senza toccare il codice chiamante.
 *
 * Nota su sincrono/asincrono: le implementazioni eseguono un callout HTTP sincrono.
 * È responsabilità del chiamante avvolgere l'invocazione in un contesto asincrono
 * (es. Queueable) quando innescata da un trigger o da un Flow, dato che i trigger non
 * possono eseguire callout direttamente.
 */
public interface PaymentLinkProvider {
    PaymentLinkResult createPaymentLink(PaymentLinkRequest request);
}
