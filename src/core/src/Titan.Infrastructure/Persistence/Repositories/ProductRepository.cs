using Microsoft.EntityFrameworkCore;
using Titan.Domain.Entities;
using Titan.Domain.Interfaces;

namespace Titan.Infrastructure.Persistence.Repositories;

public class ProductRepository : IProductRepository
{
    private readonly TitanDbContext _context;

    public ProductRepository(TitanDbContext context) => _context = context;

    public async Task<Product?> GetByIdAsync(string id, CancellationToken ct = default)
        => await _context.Products.FindAsync(new object[] { id }, ct);

    public async Task<IReadOnlyList<Product>> GetAllAsync(CancellationToken ct = default)
        => await _context.Products.ToListAsync(ct);

    public async Task<IReadOnlyList<Product>> GetByWarehouseAsync(string warehouseId, CancellationToken ct = default)
        => await _context.Products.Where(p => p.WarehouseId == warehouseId).ToListAsync(ct);

    public async Task<IReadOnlyList<Product>> GetAvailableForIssueAsync(string warehouseId, CancellationToken ct = default)
        => await _context.Products.Where(p => p.WarehouseId == warehouseId && p.IsReceived && p.CanIssue).ToListAsync(ct);

    public async Task AddAsync(Product entity, CancellationToken ct = default)
    {
        await _context.Products.AddAsync(entity, ct);
        await _context.SaveChangesAsync(ct);
    }

    public async Task UpdateAsync(Product entity, CancellationToken ct = default)
    {
        _context.Products.Update(entity);
        await _context.SaveChangesAsync(ct);
    }

    public async Task DeleteAsync(string id, CancellationToken ct = default)
    {
        var entity = await GetByIdAsync(id, ct);
        if (entity != null)
        {
            _context.Products.Remove(entity);
            await _context.SaveChangesAsync(ct);
        }
    }
}
