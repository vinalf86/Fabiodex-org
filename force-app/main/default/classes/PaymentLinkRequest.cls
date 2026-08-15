/**
 * Dati in ingresso per generare un link di pagamento, indipendenti dal gateway.
 * Il dispatcher li costruisce a partire dall'Opportunity (importo, record Id) prima di
 * passarli all'implementazione di PaymentLinkProvider risolta dal campo piattaforma.
 */
public class PaymentLinkRequest {

    /** Id del record Salesforce (Opportunity) da correlare all'ordine sul gateway. */
    public Id recordId;

    /** Importo da pagare in unità standard (es. 150.00 = 150€), non in unità minori. */
    public Decimal amount;

    /** Codice valuta ISO 4217, es. 'EUR'. */
    public String currencyCode;

    /** URL opzionale a cui reindirizzare il pagatore dopo il pagamento. */
    public String redirectUrl;

    /** Scadenza opzionale dell'ordine non pagato, formato ISO 8601 (es. 'PT30M'). */
    public String expireAfter;

    /** Metadata opzionali aggiuntivi da propagare al gateway per ridondanza/riconciliazione. */
    public Map<String, String> metadata;

    public PaymentLinkRequest(Id recordId, Decimal amount, String currencyCode) {
        this.recordId = recordId;
        this.amount = amount;
        this.currencyCode = currencyCode;
        this.metadata = new Map<String, String>();
    }
}
