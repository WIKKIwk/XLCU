namespace Titan.Domain.ValueObjects;

public sealed record EpcCode
{
    public string Value { get; }

    private EpcCode(string value) => Value = value;

    public static EpcCode Create(string prefix, long counter)
    {
        var hexCounter = counter.ToString("X12");
        return new EpcCode($"{prefix}{hexCounter}");
    }

    public static EpcCode FromString(string value)
    {
        if (string.IsNullOrEmpty(value) || value.Length != 24)
            throw new ArgumentException("Invalid EPC code format");
        return new EpcCode(value.ToUpper());
    }

    public override string ToString() => Value;
}
