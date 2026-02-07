namespace Titan.Domain.Interfaces;

public interface ICacheService
{
    Task<T?> GetAsync<T>(string key, CancellationToken ct = default) where T : class;
    Task SetAsync<T>(string key, T value, TimeSpan? expiration = null, CancellationToken ct = default) where T : class;
    Task RemoveAsync(string key, CancellationToken ct = default);
    Task<bool> ExistsAsync(string key, CancellationToken ct = default);
}
