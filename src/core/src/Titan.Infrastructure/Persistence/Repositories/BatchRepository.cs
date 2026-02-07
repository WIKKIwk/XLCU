using Microsoft.EntityFrameworkCore;
using Titan.Domain.Entities;
using Titan.Domain.Interfaces;

namespace Titan.Infrastructure.Persistence.Repositories;

public class BatchRepository : IBatchRepository
{
    private readonly TitanDbContext _context;

    public BatchRepository(TitanDbContext context) => _context = context;

    public async Task<Batch?> GetByIdAsync(string id, CancellationToken ct = default)
        => await _context.Batches.FindAsync(new object[] { id }, ct);

    public async Task<IReadOnlyList<Batch>> GetAllAsync(CancellationToken ct = default)
        => await _context.Batches.ToListAsync(ct);

    public async Task<Batch?> GetActiveAsync(CancellationToken ct = default)
        => await _context.Batches.FirstOrDefaultAsync(b => b.Status == BatchStatus.Running, ct);

    public async Task AddAsync(Batch entity, CancellationToken ct = default)
    {
        await _context.Batches.AddAsync(entity, ct);
        await _context.SaveChangesAsync(ct);
    }

    public async Task UpdateAsync(Batch entity, CancellationToken ct = default)
    {
        _context.Batches.Update(entity);
        await _context.SaveChangesAsync(ct);
    }

    public async Task DeleteAsync(string id, CancellationToken ct = default)
    {
        var entity = await GetByIdAsync(id, ct);
        if (entity != null)
        {
            _context.Batches.Remove(entity);
            await _context.SaveChangesAsync(ct);
        }
    }
}
