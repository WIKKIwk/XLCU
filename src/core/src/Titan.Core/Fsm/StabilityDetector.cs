namespace Titan.Core.Fsm;

public sealed class StabilityDetector
{
    private readonly Queue<WeightSample> _samples = new();
    private readonly StabilityConfiguration _config;

    public double Mean { get; private set; }
    public double StdDev { get; private set; }
    public bool IsStable { get; private set; }
    public int TotalSamples => _samples.Count;
    public double PlacementMinWeight { get; private set; } = 1.0;

    public StabilityDetector(StabilityConfiguration? config = null)
    {
        _config = config ?? StabilityConfiguration.Default;
    }

    public void SetPlacementMinWeight(double value) => PlacementMinWeight = value;

    public void AddSample(WeightSample sample)
    {
        _samples.Enqueue(sample);

        while (_samples.Count > 0)
        {
            var oldest = _samples.Peek();
            if (sample.Timestamp - oldest.Timestamp > _config.WindowSeconds)
                _samples.Dequeue();
            else
                break;
        }

        CalculateStatistics();
        CheckStability();
    }

    public void Reset()
    {
        _samples.Clear();
        Mean = 0;
        StdDev = 0;
        IsStable = false;
    }

    private void CalculateStatistics()
    {
        if (_samples.Count == 0) return;

        var values = _samples.Select(s => s.Value).ToList();
        Mean = values.Average();

        if (values.Count > 1)
        {
            var variance = values.Select(v => (v - Mean) * (v - Mean)).Average();
            StdDev = Math.Sqrt(variance);
        }
        else
        {
            StdDev = 0;
        }
    }

    private void CheckStability()
    {
        if (_samples.Count < _config.MinSamples)
        {
            IsStable = false;
            return;
        }

        var values = _samples.Select(s => s.Value).ToList();
        var maxChange = values.Max() - values.Min();

        IsStable = maxChange <= _config.Eps && StdDev <= _config.Sigma;
    }
}
