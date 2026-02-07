using Microsoft.EntityFrameworkCore;
using Titan.Domain.Entities;

namespace Titan.Infrastructure.Persistence;

public class TitanDbContext : DbContext
{
    public DbSet<Product> Products => Set<Product>();
    public DbSet<Batch> Batches => Set<Batch>();
    public DbSet<WeightRecord> WeightRecords => Set<WeightRecord>();
    public DbSet<EpcSequence> EpcSequences => Set<EpcSequence>();

    public TitanDbContext(DbContextOptions<TitanDbContext> options) : base(options)
    {
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Product>(entity =>
        {
            entity.HasKey(e => e.Id);
            entity.Property(e => e.Name).HasMaxLength(255).IsRequired();
            entity.Property(e => e.WarehouseId).HasMaxLength(64).IsRequired();
            entity.HasIndex(e => e.WarehouseId);
            entity.HasIndex(e => new { e.WarehouseId, e.IsReceived, e.CanIssue });
        });

        modelBuilder.Entity<Batch>(entity =>
        {
            entity.HasKey(e => e.Id);
            entity.Property(e => e.Name).HasMaxLength(255).IsRequired();
            entity.Property(e => e.WarehouseId).HasMaxLength(64).IsRequired();
            entity.Property(e => e.Status).HasConversion<string>().HasMaxLength(20);
            entity.HasIndex(e => e.Status);
            entity.HasIndex(e => new { e.Status, e.StartedAt });
        });

        modelBuilder.Entity<WeightRecord>(entity =>
        {
            entity.HasKey(e => e.Id);
            entity.Property(e => e.BatchId).HasMaxLength(64).IsRequired();
            entity.Property(e => e.ProductId).HasMaxLength(64).IsRequired();
            entity.Property(e => e.Unit).HasMaxLength(10).IsRequired();
            entity.Property(e => e.EpcCode).HasMaxLength(24).IsRequired();
            entity.HasIndex(e => e.BatchId);
            entity.HasIndex(e => e.IsSynced);
            entity.HasIndex(e => e.EpcCode).IsUnique();
        });

        modelBuilder.Entity<EpcSequence>(entity =>
        {
            entity.HasKey(e => e.Prefix);
            entity.Property(e => e.Prefix).HasMaxLength(12);
        });
    }
}

public class EpcSequence
{
    public string Prefix { get; set; } = string.Empty;
    public long LastValue { get; set; }
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
}
