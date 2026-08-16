/**
 * Helper generici e riusabili per i flussi di generazione link di pagamento (oggi solo
 * Revolut). Non contiene nulla di specifico di un gateway: se in futuro arriverà Stripe/
 * PayPal, questi due elementi restano validi così come sono.
 */
public class PaymentLinkUtils {

    /**
     * Eccezione per errori di validazione/input a monte del callout (es. Opportunity senza
     * un importo valido, troppi record in un'unica chiamata bulk). Distinta dai fallimenti
     * "attesi" del gateway (quelli restano gestiti come Log__c senza stack trace, non come
     * eccezione): questa segnala un problema del chiamante o un limite di piattaforma.
     */
    public class PaymentLinkException extends Exception {
    }

    /**
     * Converte un importo in unità standard (es. 150.00€) nella rappresentazione in unità
     * minori ISO 4217 richiesta da Revolut (es. 15000), con arrotondamento esplicito a 2
     * decimali — mai troncamento. Assunzione: valute a 2 decimali (EUR e la maggior parte
     * di quelle supportate da Revolut).
     */
    public static Long toMinorUnits(Decimal amount) {
        return (amount * 100).setScale(0, System.RoundingMode.HALF_UP).longValue();
    }
}
