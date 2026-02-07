using Microsoft.EntityFrameworkCore;
using Titan.Domain.Entities;
using Titan.Domain.Interfaces;

namespace Titan.Infrastructure.Persistence.Repositories;

public class WeightRecordRepository : IWeightRecordRepository
{
    private readonly TitanDbContext _context;

    public WeightRecordRepository(TitanDbContext context) => _context = context;

    public async Task<WeightRecord?> GetByIdAsync(string id, CancellationToken ct = default)
        => await _context.WeightRecords.FindAsync(new object[] { id }, ct);

    public async Task<IReadOnlyList<WeightRecord>> GetAllAsync(CancellationToken ct = default)
        => await _context.WeightRecords.ToListAsync(ct);

    public async Task<IReadOnlyList<WeightRecord>> GetUnsyncedAsync(CancellationToken ct = default)
        => await _context.WeightRecords.Where(r => !r.IsSynced).OrderBy(r => r.RecordedAt).ToListAsync(ct);

    public async Task MarkAsSyncedAsync(string id, CancellationToken ct = default)
    {
        var record = await GetByIdAsync(id, ct);
        if (record != null)
        {
            record.MarkAsSynced();
            await _context.SaveChangesAsync(ct);
        }
    }

    public async Task AddAsync(WeightRecord entity, CancellationToken ct = default)
    {
        await _context.WeightRecords.AddAsync(entity, ct);
        await _context.SaveChangesAsync(ct);
    }

    public async Task UpdateAsync(WeightRecord entity, CancellationToken ct = default)
    {
        _context.WeightRecords.Update(entity);
        await _context.SaveChangesAsync(ct);
    }

    public async Task DeleteAsync(string id, CancellationToken ct = default)
    {
        var entity = await GetByIdAsync(id, ct);
        if (entity != null)
        {
            _context.WeightRecords.Remove(entity);
            await _context.SaveChangesAsync(ct);
        }
    }
}
