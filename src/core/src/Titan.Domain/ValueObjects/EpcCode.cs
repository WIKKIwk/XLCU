namespace Titan.Domain.ValueObjects;

public sealed record EpcCode
{
    private const int PrefixLength = 15;  // 60-bit hex prefix
    private const int SuffixLength = 8;   // 32-bit hex counter
    private const int TotalLength = PrefixLength + SuffixLength;

    public string Value { get; }

    private EpcCode(string value) => Value = value;

    public static EpcCode Create(string prefix, long counter)
    {
        if (string.IsNullOrWhiteSpace(prefix))
            throw new ArgumentException("prefix is required", nameof(prefix));
        if (prefix.Length != PrefixLength)
            throw new ArgumentException($"prefix must be {PrefixLength} hex chars", nameof(prefix));
        if (counter < 0)
            throw new ArgumentOutOfRangeException(nameof(counter), "counter must be non-negative");

        // Keep EPC length stable (prefix + 32-bit counter). If we ever need more bits,
        // bump the suffix length and update all systems consistently.
        if (counter > uint.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(counter), "counter too large for 32-bit suffix");

        var hexCounter = counter.ToString("X")!.PadLeft(SuffixLength, '0');
        var value = $"{prefix}{hexCounter}".ToUpperInvariant();
        return FromString(value);
    }

    public static EpcCode FromString(string value)
    {
        if (string.IsNullOrEmpty(value) || value.Length != TotalLength)
            throw new ArgumentException("Invalid EPC code format");

        for (var i = 0; i < value.Length; i++)
        {
            var c = value[i];
            var isHex =
                (c >= '0' && c <= '9') ||
                (c >= 'a' && c <= 'f') ||
                (c >= 'A' && c <= 'F');
            if (!isHex)
                throw new ArgumentException("Invalid EPC code format");
        }

        return new EpcCode(value.ToUpperInvariant());
    }

    public override string ToString() => Value;
}
