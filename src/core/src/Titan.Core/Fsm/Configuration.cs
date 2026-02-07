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
        Sigma: 0.01,
        Eps: 0.03,
        EpsAlign: 0.06,
        WindowSeconds: 1.0,
        MinSamples: 10
    );
}
