/**
 * Esito, indipendente dal gateway, di una richiesta di link di pagamento.
 *
 * Volutamente NON lancia mai eccezioni per un fallimento "atteso" (4xx, timeout, risposta
 * malformata): isSuccess = false con errorMessage/statusCode valorizzati. Così il chiamante
 * (dispatcher, Queueable) decide in un unico punto se creare un Log__c e schedulare un retry,
 * senza dover distinguere try/catch per ogni tipo di fallimento del gateway.
 * requestBody/responseBody sono pensati per finire (eventualmente troncati dal chiamante)
 * nel Log__c, sia per diagnosi sia come payload di replay per il retry.
 */
public class PaymentLinkResult {

    public Boolean isSuccess;

    /** Valorizzati solo quando isSuccess = true. */
    public String checkoutUrl;
    public String externalOrderId;
    public String externalOrderToken;
    public String externalState;

    /** Sempre valorizzati quando disponibili, sia in successo che in fallimento. */
    public Integer statusCode;
    public String requestBody;
    public String responseBody;

    /** Valorizzato solo quando isSuccess = false. */
    public String errorMessage;

    private PaymentLinkResult() {
    }

    public static PaymentLinkResult success(String externalOrderId, String externalOrderToken,
            String checkoutUrl, String externalState, String requestBody, String responseBody,
            Integer statusCode) {

        PaymentLinkResult result = new PaymentLinkResult();
        result.isSuccess = true;
        result.externalOrderId = externalOrderId;
        result.externalOrderToken = externalOrderToken;
        result.checkoutUrl = checkoutUrl;
        result.externalState = externalState;
        result.requestBody = requestBody;
        result.responseBody = responseBody;
        result.statusCode = statusCode;
        return result;
    }

    public static PaymentLinkResult failure(String requestBody, String responseBody,
            Integer statusCode, String errorMessage) {

        PaymentLinkResult result = new PaymentLinkResult();
        result.isSuccess = false;
        result.requestBody = requestBody;
        result.responseBody = responseBody;
        result.statusCode = statusCode;
        result.errorMessage = errorMessage;
        return result;
    }
}
