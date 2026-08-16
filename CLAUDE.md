# Progetto: Generazione link di pagamento Revolut da Salesforce

## Contesto
Integrazione Salesforce ↔ Revolut per generare link di pagamento dinamici da inviare ai clienti finali. Fase 1: solo Revolut. Fasi successive: PayPal e Stripe, riusando la stessa architettura. Lo sviluppatore ha discreta conoscenza di Apex; questa è la sua prima integrazione con API esterne — preferire spiegazioni chiare dei pattern usati (callout, mock, async).

## Requisiti funzionali
1. Da un'Opportunity, generare un link di pagamento Revolut (hosted checkout) in base a:
   - un campo custom che indica la piattaforma di pagamento (per ora solo "Revolut"; il dispatch deve essere dinamico e pronto per PayPal/Stripe)
   - un campo custom con l'importo da pagare
2. Salvare il `checkout_url` restituito su un campo dell'Opportunity.
3. Alla conferma del pagamento (webhook Revolut, evento ORDER_COMPLETED), aggiornare lo Stage dell'Opportunity a Chiusa Vinta.
4. Oggetto custom di log errori con: gateway, request/response (troncati), status code, record correlato, stato (Resend / Sent / Failed), contatore tentativi, timestamp ultimo tentativo, payload della richiesta per il replay.
5. Meccanismo di retry: Scheduled Apex che riprende i log "In retry" con contatore sotto soglia (3) e rilancia la chiamata; oltre soglia marca "Fallito definitivo".

## Architettura decisa
- Interfaccia `PaymentLinkProvider` + implementazione `RevolutPaymentLinkProvider` (Strategy pattern).
- Dispatcher che risolve l'implementazione dal campo piattaforma dell'Opportunity.
- Callout asincroni (Queueable) se innescati da trigger/Flow; valutare Invocable Action per il Flow.
- Named Credential / External Credential per l'autenticazione (mai chiavi nel codice).
- Endpoint webhook: classe `@RestResource` esposta via Site pubblico (guest user), con validazione firma HMAC di Revolut, idempotenza (evento duplicato su Opportunity già chiusa non deve fallire né duplicare log), log anche degli inbound.
- Nessun pacchetto AppExchange: tutto custom per uniformità tra i tre gateway futuri.

## API Revolut Merchant — dettagli verificati (versione 2026-04-20)
- Sandbox base URL: `https://sandbox-merchant.revolut.com` (produzione: `https://merchant.revolut.com`). Chiavi e account Sandbox/Production completamente separati.
- Auth: header `Authorization: Bearer <Secret API key>` (chiave `sk_...`, NON la Public `pk_...`).
- Header obbligatorio: `Revolut-Api-Version: 2026-04-20` (senza, errore).
- Creazione ordine: `POST /api/orders`, body JSON. Campi obbligatori: `amount` (unità minori ISO 4217: 15000 = €150,00) e `currency` (ISO 4217 maiuscolo).
- Riferimento esterno per riconciliazione: `merchant_order_data.reference` → metterci il record Id Salesforce. In questa versione NON esiste più `merchant_order_ext_ref` piatto. Ridondanza consigliata anche in `metadata` (coppie stringa, chiavi `^[a-zA-Z][a-zA-Z\d_]{0,39}$`, valori max 500 char).
- `redirect_url` opzionale: redirect post-pagamento dalla pagina hosted.
- `expire_pending_after` opzionale (ISO 8601, PT1M–PT720H, solo in creazione): scadenza automatica dell'ordine non pagato → evento ORDER_FAILED.
- Risposta 201: `id`, `token`, `state: "pending"`, `checkout_url` (`https://checkout.revolut.com/payment-link/<token>`).
- Stati ordine: pending → processing → authorised → completed | cancelled | failed. Con `capture_mode: automatic` (default) lo stato che chiude l'Opportunity è **completed** (evento webhook ORDER_COMPLETED, non fermarsi ad authorised).
- Lista ordini filtrabile per `merchant_order_data_reference` → utile nel retry per verificare se un ordine esiste già (caso "timeout dopo successo", per evitare duplicati).
- Docs: https://developer.revolut.com/docs/merchant/create-order · https://developer.revolut.com/docs/merchant/webhooks

## Punti d'attenzione già identificati
- Conversione importo: campo decimale → unità minori con arrotondamento esplicito (mai troncamento).
- Guest user del Site: restrizioni pesanti di default; update dell'Opportunity probabilmente `without sharing` o via Queueable.
- Verificare automazioni esistenti a valle della chiusura Opportunity (Flow, trigger): il webhook le scatena in contesto guest/system.
- Test class: HttpCalloutMock per successo, 4xx, timeout, risposta malformata; test endpoint REST con payload firmati e non; test retry.
- Smoke test Postman: già in corso (risolvere 401 = problemi tipici di chiave/environment; usare Postman Console per l'header effettivo).
- Deploy: le Named Credentials vanno riconfigurate a mano in produzione con le chiavi live; webhook da ripuntare sull'endpoint di produzione; prerequisito: Merchant account Revolut del cliente attivo e approvato (KYC).

## Stima concordata
Fase 1 (solo Revolut, webhook incluso): 10 giornate. Fasi 2-3 (PayPal, Stripe): ~3-4 giornate ciascuna.

## Prossimi passi
1. Completare smoke test Postman (401 in corso di risoluzione).
2. Data model: campi su Opportunity + oggetto log errori.
3. Interfaccia + implementazione Revolut + dispatcher.
4. Retry (Scheduled Apex) e test class.
5. Site + endpoint webhook + validazione HMAC + chiusura Opportunity.
