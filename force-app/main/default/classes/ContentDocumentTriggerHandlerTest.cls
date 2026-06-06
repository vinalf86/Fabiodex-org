@isTest
private class ContentDocumentTriggerHandlerTest {

    // Metodo di utilità per creare il Custom Setting
    private static void createUserIdsSetting() {
        UserIds__c setting = new UserIds__c();
        setting.Sabrina__c = UserInfo.getUserId();
        setting.Fabio__c   = UserInfo.getUserId();
        insert setting;
    }

    // Metodo di utilità per creare un Lead
    private static Lead createLead() {
        Lead l = new Lead(
            FirstName           = 'Test',
            LastName            = 'Lead',
            Company             = 'Test Company',
            Email               = 'test.lead@example.com',
            Phone               = '1234567890',
            Event_Start_Date__c = Date.today(),
            Event_End_Date__c   = Date.today().addDays(1)
        );
        insert l;
        return l;
    }

    // Metodo di utilità per creare un'Opportunità
    private static Opportunity createOpportunity(String stageName) {
        Lead l = createLead();
        Opportunity opp = new Opportunity(
            Name                = 'Test Opportunity',
            StageName           = stageName,
            CloseDate           = Date.today().addDays(30),
            Event_Start_Date__c = Date.today(),
            Event_End_Date__c   = Date.today().addDays(1),
            Lead__c             = l.Id
        );
        insert opp;
        return opp;
    }

    // Metodo di utilità che crea ContentVersion + ContentDocumentLink
    // e restituisce il ContentDocument per poter chiamare l'handler direttamente
    private static ContentDocument createContentDocumentWithLink(Id linkedEntityId, String title) {
        ContentVersion cv = new ContentVersion(
            Title          = title,
            PathOnClient   = title + '.pdf',
            VersionData    = Blob.valueOf('Test content'),
            IsMajorVersion = true
        );
        insert cv;

        Id contentDocumentId = [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cv.Id
        ].ContentDocumentId;

        ContentDocumentLink cdl = new ContentDocumentLink(
            ContentDocumentId = contentDocumentId,
            LinkedEntityId    = linkedEntityId,
            ShareType         = 'V'
        );
        insert cdl;

        return [
            SELECT Id, Title
            FROM ContentDocument
            WHERE Id = :contentDocumentId
        ];
    }

    // Scenario 1: file 'Contratto firmato' legato a un'Opportunità con stage aggiornabile → successo
    @isTest
    static void testAfterInsert_ContractFile_UpdatesOpportunity() {
        createUserIdsSetting();
        Opportunity opp = createOpportunity('Prospecting');

        Test.startTest();
        ContentDocument cd = createContentDocumentWithLink(opp.Id, 'Contratto firmato');
        new ContentDocumentTriggerHandler().afterInsertHandler(new List<ContentDocument>{ cd });
        Test.stopTest();

        Opportunity updatedOpp = [SELECT StageName FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Contratto firmato', updatedOpp.StageName,
            'Lo stage avrebbe dovuto essere aggiornato a Contratto firmato');
    }

    // Scenario 2: file con nome diverso da 'Contratto firmato' → nessun aggiornamento
    @isTest
    static void testAfterInsert_NonContractFile_NoUpdate() {
        createUserIdsSetting();
        Opportunity opp = createOpportunity('Prospecting');

        Test.startTest();
        ContentDocument cd = createContentDocumentWithLink(opp.Id, 'Invoice');
        new ContentDocumentTriggerHandler().afterInsertHandler(new List<ContentDocument>{ cd });
        Test.stopTest();

        Opportunity updatedOpp = [SELECT StageName FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Prospecting', updatedOpp.StageName,
            'Lo stage non avrebbe dovuto essere modificato');
    }

    // Scenario 3: Opportunità già in 'Contratto firmato' → nessun aggiornamento
    @isTest
    static void testAfterInsert_AlreadyContratto_NoUpdate() {
        createUserIdsSetting();
        Opportunity opp = createOpportunity('Contratto firmato');

        Test.startTest();
        ContentDocument cd = createContentDocumentWithLink(opp.Id, 'Contratto firmato');
        new ContentDocumentTriggerHandler().afterInsertHandler(new List<ContentDocument>{ cd });
        Test.stopTest();

        Opportunity updatedOpp = [SELECT StageName FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Contratto firmato', updatedOpp.StageName,
            'Lo stage era già Contratto firmato e non doveva cambiare');
    }

    // Scenario 4: Opportunità già in 'Chiuse/Conseguite' → nessun aggiornamento
    @isTest
    static void testAfterInsert_AlreadyChiuse_NoUpdate() {
        createUserIdsSetting();
        Opportunity opp = createOpportunity('Chiuse/Conseguite');

        Test.startTest();
        ContentDocument cd = createContentDocumentWithLink(opp.Id, 'Contratto firmato');
        new ContentDocumentTriggerHandler().afterInsertHandler(new List<ContentDocument>{ cd });
        Test.stopTest();

        Opportunity updatedOpp = [SELECT StageName FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Chiuse/Conseguite', updatedOpp.StageName,
            'Lo stage era già Chiuse/Conseguite e non doveva cambiare');
    }

    // Scenario 5: file 'Contratto firmato' legato a un record che NON è un'Opportunità → nessun aggiornamento
    @isTest
    static void testAfterInsert_ContractLinkedToNonOpportunity_NoUpdate() {
        createUserIdsSetting();

        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Test.startTest();
        ContentDocument cd = createContentDocumentWithLink(acc.Id, 'Contratto firmato');
        new ContentDocumentTriggerHandler().afterInsertHandler(new List<ContentDocument>{ cd });
        Test.stopTest();

        List<Opportunity> opps = [SELECT Id FROM Opportunity WHERE StageName = 'Contratto firmato'];
        Assert.areEqual(0, opps.size(),
            'Nessuna Opportunità avrebbe dovuto essere aggiornata');
    }

    // Scenario 6: lista nulla in input → nessuna eccezione
    @isTest
    static void testAfterInsert_NullInput_NoException() {
        Test.startTest();
        try {
            new ContentDocumentTriggerHandler().afterInsertHandler(null);
            Assert.isTrue(true, 'Nessuna eccezione attesa con input nullo');
        } catch (Exception e) {
            Assert.fail('Non avrebbe dovuto lanciare eccezioni: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // Scenario 7: lista vuota in input → nessuna eccezione
    @isTest
    static void testAfterInsert_EmptyList_NoException() {
        Test.startTest();
        try {
            new ContentDocumentTriggerHandler().afterInsertHandler(new List<ContentDocument>());
            Assert.isTrue(true, 'Nessuna eccezione attesa con lista vuota');
        } catch (Exception e) {
            Assert.fail('Non avrebbe dovuto lanciare eccezioni: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // Scenario 8: Custom Setting senza Id utenti → notifica non inviata ma nessuna eccezione
    @isTest
    static void testAfterInsert_EmptyCustomSetting_NoException() {
        UserIds__c setting = new UserIds__c();
        insert setting;

        Opportunity opp = createOpportunity('Prospecting');

        Test.startTest();
        try {
            ContentDocument cd = createContentDocumentWithLink(opp.Id, 'Contratto firmato');
            new ContentDocumentTriggerHandler().afterInsertHandler(new List<ContentDocument>{ cd });
            Assert.isTrue(true, 'Nessuna eccezione attesa con Custom Setting vuoto');
        } catch (Exception e) {
            Assert.fail('Non avrebbe dovuto lanciare eccezioni: ' + e.getMessage());
        }
        Test.stopTest();
    }
}