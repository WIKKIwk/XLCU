using System.Runtime.CompilerServices;
using Titan.Core.Fsm;

namespace Titan.Integration.Tests.Simulation;

public class WeightStreamSimulator
{
    private readonly List<WeightSample> _samples = new();
    private int _currentIndex = 0;
    private double _baseTime;

    public WeightStreamSimulator()
    {
        _baseTime = (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;
    }

    public void AddStablePhase(double weight, double duration, double sampleRate = 0.1)
    {
        int numSamples = (int)(duration / sampleRate);
        var random = new Random();

        for (int i = 0; i < numSamples; i++)
        {
            var noise = (random.NextDouble() - 0.5) * 0.01;
            _samples.Add(new WeightSample(weight + noise, "kg", _baseTime + _samples.Count * sampleRate));
        }
    }

    public void AddRamp(double startWeight, double endWeight, double duration, double sampleRate = 0.1)
    {
        int numSamples = (int)(duration / sampleRate);
        double step = (endWeight - startWeight) / numSamples;

        for (int i = 0; i < numSamples; i++)
        {
            _samples.Add(new WeightSample(startWeight + step * i, "kg", _baseTime + _samples.Count * sampleRate));
        }
    }

    public void AddTransient(double spikeWeight, double duration, double sampleRate = 0.1)
    {
        int numSamples = (int)(duration / sampleRate);
        for (int i = 0; i < numSamples; i++)
        {
            _samples.Add(new WeightSample(spikeWeight, "kg", _baseTime + _samples.Count * sampleRate));
        }
    }

    public IReadOnlyList<WeightSample> GetSamples() => _samples.AsReadOnly();

    public IAsyncEnumerable<WeightSample> StreamAsync([EnumeratorCancellation] CancellationToken ct = default)
    {
        return StreamInternalAsync(ct);
    }

    private async IAsyncEnumerable<WeightSample> StreamInternalAsync([EnumeratorCancellation] CancellationToken ct)
    {
        while (_currentIndex < _samples.Count && !ct.IsCancellationRequested)
        {
            yield return _samples[_currentIndex];
            _currentIndex++;
            await Task.Delay(10, ct);
        }
    }

    public void Reset()
    {
        _currentIndex = 0;
    }

    public int TotalSamples => _samples.Count;
}
