namespace Titan.Core.Fsm;

public sealed record WeightSample(
    double Value,
    string Unit,
    double Timestamp
);

public sealed record FsmConfiguration(
    double SettleSeconds,
    double ClearSeconds,
    int MinSamples,
    double EmptyThreshold,
    double Eps,
    double EpsAlign
)
{
    public static FsmConfiguration Default => new(
        SettleSeconds: 0.50,
        ClearSeconds: 0.70,
        MinSamples: 10,
        EmptyThreshold: 0.05,
        Eps: 0.03,
        EpsAlign: 0.06
    );
}

public sealed record StabilityConfiguration(
    double Sigma,
    double Eps,
    double EpsAlign,
    double WindowSeconds,
    int MinSamples
)
{
    public static StabilityConfiguration Default => new(
        // Default stability thresholds for typical industrial scales.
        // Keep these aligned with tests and real-world noise characteristics.
        Sigma: 0.015,
        Eps: 0.05,
        EpsAlign: 0.06,
        WindowSeconds: 1.0,
        MinSamples: 10
    );
}
