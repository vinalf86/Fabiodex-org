/**
 * Eccezione per errori di programmazione/input (es. richiesta incompleta) comuni a tutte
 * le implementazioni di PaymentLinkProvider. Distinta dai fallimenti "attesi" del gateway
 * (4xx, timeout...), che invece sono rappresentati da PaymentLinkResult.isSuccess = false:
 * questa eccezione segnala un bug del chiamante (es. amount nullo), non un problema
 * dell'API esterna, quindi deve propagarsi invece di essere silenziosamente loggata come
 * fallimento di gateway.
 */
public class PaymentLinkProviderException extends Exception {
}
