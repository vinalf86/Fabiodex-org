public class PaymentLinkUtils {

    public class PaymentLinkException extends Exception {
    }

    public static Long toMinorUnits(Decimal amount) {
        return (amount * 100).setScale(0, System.RoundingMode.HALF_UP).longValue();
    }
}
