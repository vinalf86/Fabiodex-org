/**
 * Implementazione Revolut Merchant API (versione 2026-04-20) di PaymentLinkProvider.
 * Crea un ordine (hosted checkout) e restituisce l'URL di pagamento da salvare
 * sull'Opportunity.
 *
 * Prerequisito da configurare a mano in Setup (NON gestito da questa classe, per non
 * mettere mai una chiave nel codice):
 * - Named Credential con DeveloperName "Revolut_Merchant", URL = base Merchant API
 *   (sandbox: https://sandbox-merchant.revolut.com — produzione: https://merchant.revolut.com).
 * - External Credential collegata, protocollo "Custom", con un principal che espone la
 *   Secret API key (sk_...) e la inietta come header "Authorization: Bearer <chiave>" a
 *   livello di Named Credential. Il codice qui sotto non imposta mai l'header Authorization:
 *   ci pensa la Named Credential in automatico ad ogni callout su "callout:Revolut_Merchant".
 * - L'header "Revolut-Api-Version" invece non è un segreto: viene impostato qui in Apex.
 *
 * Nota: il callout è sincrono. Se invocata da un trigger o da un Flow, questa classe va
 * chiamata da un contesto già asincrono (es. Queueable), perché i trigger non possono
 * eseguire callout HTTP direttamente.
 */
public with sharing class RevolutPaymentLinkProvider implements PaymentLinkProvider {

    @TestVisible
    private static final String NAMED_CREDENTIAL_ENDPOINT = 'callout:Revolut_Merchant';
    private static final String ORDERS_PATH = '/api/orders';
    private static final String API_VERSION_HEADER = 'Revolut-Api-Version';
    private static final String API_VERSION = '2026-04-20';
    private static final Integer TIMEOUT_MS = 30000;
    private static final Integer HTTP_CREATED = 201;

    public PaymentLinkResult createPaymentLink(PaymentLinkRequest request) {
        validate(request);

        String requestBody = buildRequestBody(request);
        HttpResponse response;

        try {
            response = sendCallout(requestBody);
        } catch (System.CalloutException ex) {
            // Timeout, DNS, endpoint non raggiungibile, Named Credential non configurata...
            // Non è un fallimento "di dominio" del gateway: lo trattiamo comunque come esito
            // negativo (non un'eccezione) così il chiamante può loggare e ritentare in modo
            // uniforme, indipendentemente dalla causa del fallimento.
            return PaymentLinkResult.failure(requestBody, null, null, 'Callout fallito: ' + ex.getMessage());
        }

        return parseResponse(requestBody, response);
    }

    private void validate(PaymentLinkRequest request) {
        if (request == null) {
            throw new PaymentLinkProviderException('PaymentLinkRequest non può essere null.');
        }
        if (request.recordId == null) {
            throw new PaymentLinkProviderException(
                'recordId obbligatorio: serve come merchant_order_data.reference per la riconciliazione.');
        }
        if (request.amount == null || request.amount <= 0) {
            throw new PaymentLinkProviderException('amount deve essere un valore positivo.');
        }
        if (String.isBlank(request.currencyCode)) {
            throw new PaymentLinkProviderException('currencyCode obbligatorio (es. EUR).');
        }
    }

    private HttpResponse sendCallout(String requestBody) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL_ENDPOINT + ORDERS_PATH);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader(API_VERSION_HEADER, API_VERSION);
        req.setBody(requestBody);
        req.setTimeout(TIMEOUT_MS);

        return new Http().send(req);
    }

    private String buildRequestBody(PaymentLinkRequest request) {
        Map<String, Object> body = new Map<String, Object>();
        body.put('amount', toMinorUnits(request.amount));
        body.put('currency', request.currencyCode.toUpperCase());
        body.put('merchant_order_data', new Map<String, Object>{
            'reference' => request.recordId
        });
        body.put('metadata', buildMetadata(request));

        if (String.isNotBlank(request.redirectUrl)) {
            body.put('redirect_url', request.redirectUrl);
        }
        if (String.isNotBlank(request.expireAfter)) {
            body.put('expire_pending_after', request.expireAfter);
        }

        return JSON.serialize(body);
    }

    private Map<String, String> buildMetadata(PaymentLinkRequest request) {
        // Ridondanza consigliata dalla documentazione Revolut: merchant_order_data.reference
        // resta la fonte primaria per la riconciliazione, metadata è un backup leggibile
        // anche da eventuali strumenti Revolut lato back-office.
        Map<String, String> metadata = request.metadata != null
            ? new Map<String, String>(request.metadata)
            : new Map<String, String>();
        metadata.put('salesforce_record_id', request.recordId);
        return metadata;
    }

    @TestVisible
    private static Long toMinorUnits(Decimal amount) {
        // Arrotondamento esplicito a 2 decimali (unità minori ISO 4217, es. 150.00 -> 15000),
        // mai troncamento. Assunzione: valute a 2 decimali (EUR e la maggior parte di quelle
        // supportate da Revolut). Da rivedere se in futuro serviranno valute a 0 o 3 decimali.
        return amount.setScale(2, System.RoundingMode.HALF_UP).movePointRight(2).longValue();
    }

    private PaymentLinkResult parseResponse(String requestBody, HttpResponse response) {
        Integer statusCode = response.getStatusCode();
        String responseBody = response.getBody();

        if (statusCode != HTTP_CREATED) {
            return PaymentLinkResult.failure(requestBody, responseBody, statusCode,
                'Revolut ha risposto con status ' + statusCode + ' invece di ' + HTTP_CREATED);
        }

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        } catch (Exception ex) {
            return PaymentLinkResult.failure(requestBody, responseBody, statusCode,
                'Risposta Revolut non deserializzabile: ' + ex.getMessage());
        }

        String checkoutUrl = (String) parsed.get('checkout_url');
        if (String.isBlank(checkoutUrl)) {
            return PaymentLinkResult.failure(requestBody, responseBody, statusCode,
                'Risposta Revolut priva di checkout_url.');
        }

        return PaymentLinkResult.success(
            (String) parsed.get('id'),
            (String) parsed.get('token'),
            checkoutUrl,
            (String) parsed.get('state'),
            requestBody,
            responseBody,
            statusCode
        );
    }
}
