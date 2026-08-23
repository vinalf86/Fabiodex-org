@isTest
private class PaymentLinkUtilsTest {

    // Scenario 1: conversione in unità minori con arrotondamento esplicito, mai troncamento
    @isTest
    static void testToMinorUnits_ArrotondaEsplicitamenteSenzaTroncare() {
        Assert.areEqual(15000L, PaymentLinkUtils.toMinorUnits(150.00), 'Nessun decimale: conversione diretta');
        Assert.areEqual(15001L, PaymentLinkUtils.toMinorUnits(150.005), 'Arrotonda per eccesso: 150.005 -> 150.01');
        Assert.areEqual(15000L, PaymentLinkUtils.toMinorUnits(150.004), 'Arrotonda per difetto: 150.004 -> 150.00');
        Assert.areEqual(1L, PaymentLinkUtils.toMinorUnits(0.01), 'Importi piccoli restano precisi');
    }

    // Scenario 2: PaymentLinkException porta il messaggio passato al costruttore
    @isTest
    static void testPaymentLinkException_MessaggioRecuperabile() {
        PaymentLinkUtils.PaymentLinkException ex =
            new PaymentLinkUtils.PaymentLinkException('Caparra__c deve essere un valore positivo.');

        Assert.areEqual('Caparra__c deve essere un valore positivo.', ex.getMessage());
    }
}