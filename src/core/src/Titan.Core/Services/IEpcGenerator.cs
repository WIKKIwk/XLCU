namespace Titan.Core.Services;

public interface IEpcGenerator
{
    Task<string> GenerateNextAsync();
    Task<long> GetCurrentCounterAsync();
}
