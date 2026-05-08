@IsTest
private class EventTriggerHandlerTest {

    private static final String TEST_SUBJECT  = '1° call Fabiodex';
    private static final String TEST_EMAIL    = 'test.lead@fabiodex.it';
    private static final String STAGE_INITIAL = 'Richiesta';

    // ─────────────────────────────────────────────────────────────────────────
    // SETUP DATI
    // ─────────────────────────────────────────────────────────────────────────

    @TestSetup
    static void setupData() {
        // Custom Setting
        UserIds__c setting = new UserIds__c();
        setting.Event_Subject__c = TEST_SUBJECT;
        upsert setting;

        // Lead con email di test (usato come lookup su Opportunity e come WhoId su Event)
        Lead testLead = new Lead(
            FirstName = 'Test',
            LastName  = 'Lead Fabiodex',
            Company   = 'Fabiodex Srl',
            Email     = TEST_EMAIL,
            Event_Start_Date__c = Date.today(),
            Event_End_Date__c = Date.today() + 1
        );
        insert testLead;

        // Account di supporto (obbligatorio su Opportunity)
        Account acc = new Account(Name = 'Test Account Fabiodex');
        insert acc;

        // Opportunità con stage aperto e lookup Lead__c valorizzata
        Opportunity opp = new Opportunity(
            Name      = 'Test Opp Fabiodex',
            AccountId = acc.Id,
            StageName = STAGE_INITIAL,
            CloseDate = Date.today().addMonths(1),
            Lead__c   = testLead.Id,
            Event_Start_Date__c = testLead.Event_Start_Date__c,
            Event_End_Date__c = testLead.Event_End_Date__c
        );
        insert opp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 1 — AFTER INSERT: popola Chiamata_prenotata__c e setta Vendita Fissata
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testAfterInsert_SetsDateAndStage() {
        Date eventDate = Date.today().addDays(5);
        Lead l = getTestLead();

        Test.startTest();
        Event ev = buildEvent(TEST_SUBJECT, l.Id, eventDate);
        insert ev;
        Test.stopTest();

        Opportunity result = getOpp();

        System.assertEquals('Vendita Fissata', result.StageName,
            'Lo stage deve essere aggiornato a Vendita Fissata dopo insert evento.');
        System.assertEquals(eventDate, result.Chiamata_prenotata__c,
            'Chiamata_prenotata__c deve essere valorizzata con la data dell\'evento.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 2 — AFTER UPDATE: aggiorna solo Chiamata_prenotata__c (stage invariato)
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testAfterUpdate_UpdatesDateOnly() {
        Date originalDate = Date.today().addDays(5);
        Lead l = getTestLead();
        Event ev = buildEvent(TEST_SUBJECT, l.Id, originalDate);
        insert ev;

        // Dopo insert lo stage è Vendita Fissata — verifichiamo prima
        System.assertEquals('Vendita Fissata', getOpp().StageName);

        Test.startTest();
        ev.ActivityDate     = originalDate.addDays(10);
        ev.ActivityDateTime = DateTime.newInstance(originalDate.addDays(10), Time.newInstance(10, 0, 0, 0));
        update ev;
        Test.stopTest();

        Opportunity result = getOpp();

        System.assertEquals('Vendita Fissata', result.StageName,
            'Lo stage NON deve cambiare dopo update evento.');
        System.assertEquals(Date.today(), result.Chiamata_prenotata__c,
            'Chiamata_prenotata__c deve essere aggiornata alla data odierna dopo update.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 3 — AFTER DELETE: rimuove data e torna a stage Richiesta
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testAfterDelete_ClearsDateAndResetsStage() {
        Date eventDate = Date.today().addDays(5);
        Lead l = getTestLead();
        Event ev = buildEvent(TEST_SUBJECT, l.Id, eventDate);
        insert ev;

        System.assertEquals('Vendita Fissata', getOpp().StageName);

        Test.startTest();
        delete ev;
        Test.stopTest();

        Opportunity result = getOpp();

        System.assertEquals('Richiesta', result.StageName,
            'Lo stage deve tornare a Richiesta dopo la cancellazione dell\'evento.');
        System.assertEquals(null, result.Chiamata_prenotata__c,
            'Chiamata_prenotata__c deve essere null dopo la cancellazione dell\'evento.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 4 — Soggetto NON corrispondente: nessuna modifica all'Opportunity
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testInsert_WrongSubject_NoUpdate() {
        Lead l = getTestLead();

        Test.startTest();
        Event ev = buildEvent('Altro Soggetto', l.Id, Date.today().addDays(3));
        insert ev;
        Test.stopTest();

        Opportunity result = getOpp();

        System.assertEquals(STAGE_INITIAL, result.StageName,
            'Lo stage non deve cambiare se il soggetto non corrisponde.');
        System.assertEquals(null, result.Chiamata_prenotata__c,
            'Chiamata_prenotata__c non deve essere valorizzata se il soggetto non corrisponde.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 5 — Opportunity con stage escluso (Chiusa/Vinta): nessuna modifica
    // ─────────────────────────────────────────────────────────────────────────
    @IsTest
    static void testInsert_ClosedOpportunity_NoUpdate() {
        Opportunity opp = getOpp();
        opp.StageName = 'Chiusa/Vinta';
        update opp;

        Lead l = getTestLead();

        Test.startTest();
        Event ev = buildEvent(TEST_SUBJECT, l.Id, Date.today().addDays(3));
        insert ev;
        Test.stopTest();

        Opportunity result = getOpp();

        System.assertEquals('Chiusa/Vinta', result.StageName,
            'Un\'Opportunity Chiusa/Vinta non deve essere modificata.');
        System.assertEquals(null, result.Chiamata_prenotata__c,
            'Chiamata_prenotata__c non deve essere valorizzata su Opportunity chiusa.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HELPER
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Costruisce un Event usando WhoId (lookup al Lead) per associare l'email.
     * ev.Email non è un campo scrivibile su Event in Apex.
     */
    private static Event buildEvent(String subject, Id whoId, Date activityDate) {
        return new Event(
            Subject           = subject,
            WhoId             = whoId,
            ActivityDate      = activityDate,
            DurationInMinutes = 60,
            ActivityDateTime  = DateTime.newInstance(activityDate, Time.newInstance(10, 0, 0, 0))
        );
    }

    /** Recupera il Lead di test */
    private static Lead getTestLead() {
        return [SELECT Id, Email FROM Lead WHERE Email = :TEST_EMAIL LIMIT 1];
    }

    /** Recupera l'Opportunity di test navigando la lookup Lead__r */
    private static Opportunity getOpp() {
        return [
            SELECT Id, StageName, Chiamata_prenotata__c
            FROM Opportunity
            WHERE Lead__r.Email = :TEST_EMAIL
            LIMIT 1
        ];
    }
}