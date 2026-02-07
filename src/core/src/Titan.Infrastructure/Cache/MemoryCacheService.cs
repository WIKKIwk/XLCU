using System.Text.Json;
using Microsoft.Extensions.Caching.Memory;
using Titan.Domain.Interfaces;

namespace Titan.Infrastructure.Cache;

public class MemoryCacheService : ICacheService
{
    private readonly IMemoryCache _cache;

    public MemoryCacheService(IMemoryCache cache) => _cache = cache;

    public Task<T?> GetAsync<T>(string key, CancellationToken ct = default) where T : class
    {
        if (_cache.TryGetValue(key, out var value) && value is T typedValue)
            return Task.FromResult<T?>(typedValue);
        return Task.FromResult<T?>(null);
    }

    public Task SetAsync<T>(string key, T value, TimeSpan? expiration = null, CancellationToken ct = default) where T : class
    {
        var options = new MemoryCacheEntryOptions
        {
            AbsoluteExpirationRelativeToNow = expiration ?? TimeSpan.FromHours(1)
        };
        _cache.Set(key, value, options);
        return Task.CompletedTask;
    }

    public Task RemoveAsync(string key, CancellationToken ct = default)
    {
        _cache.Remove(key);
        return Task.CompletedTask;
    }

    public Task<bool> ExistsAsync(string key, CancellationToken ct = default)
        => Task.FromResult(_cache.TryGetValue(key, out _));
}
