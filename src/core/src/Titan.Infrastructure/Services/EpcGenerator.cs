using Microsoft.EntityFrameworkCore;
using Titan.Core.Services;
using Titan.Domain.ValueObjects;
using Titan.Infrastructure.Persistence;

namespace Titan.Infrastructure.Services;

public class EpcGenerator : IEpcGenerator
{
    private readonly TitanDbContext _context;
    private readonly string _prefix;

    public EpcGenerator(TitanDbContext context, string prefix = "3034257BF7194E4")
    {
        _context = context;
        _prefix = prefix;
    }

    public async Task<string> GenerateNextAsync()
    {
        await using var transaction = await _context.Database.BeginTransactionAsync();

        try
        {
            var sequence = await _context.EpcSequences
                .FirstOrDefaultAsync(s => s.Prefix == _prefix);

            if (sequence == null)
            {
                sequence = new EpcSequence
                {
                    Prefix = _prefix,
                    LastValue = 0,
                    UpdatedAt = DateTime.UtcNow
                };
                _context.EpcSequences.Add(sequence);
            }

            sequence.LastValue++;
            sequence.UpdatedAt = DateTime.UtcNow;

            await _context.SaveChangesAsync();
            await transaction.CommitAsync();

            var epc = EpcCode.Create(_prefix, sequence.LastValue);
            return epc.Value;
        }
        catch
        {
            await transaction.RollbackAsync();
            throw;
        }
    }

    public async Task<long> GetCurrentCounterAsync()
    {
        var sequence = await _context.EpcSequences
            .FirstOrDefaultAsync(s => s.Prefix == _prefix);

        return sequence?.LastValue ?? 0;
    }
}
