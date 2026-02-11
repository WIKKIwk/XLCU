using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Titan.Core.Services;
using Titan.Domain.Interfaces;
using Titan.Infrastructure.Cache;
using Titan.Infrastructure.Hardware.Scale;
using Titan.Infrastructure.Hardware.Printer;
using Titan.Infrastructure.Messaging;
using Titan.Infrastructure.Persistence;
using Titan.Infrastructure.Persistence.Repositories;
using Titan.Infrastructure.Services;
using Titan.TUI.Services;
using Titan.Host.HealthChecks;
using Titan.Host.Services;

namespace Titan.Host;

public class Program
{
    public static async Task Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);

        // Configuration
        builder.Configuration.AddEnvironmentVariables(prefix: "TITAN_");

        // Structured JSON logging for production
        builder.Logging.ClearProviders();
        if (builder.Environment.IsProduction())
        {
            builder.Logging.AddJsonConsole(options =>
            {
                options.IncludeScopes = true;
                options.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ";
                options.JsonWriterOptions = new System.Text.Json.JsonWriterOptions { Indented = false };
            });
        }
        else
        {
            builder.Logging.AddConsole();
        }
        builder.Logging.SetMinimumLevel(LogLevel.Information);

        // Database
        var connectionString = builder.Configuration.GetConnectionString("PostgreSQL");
        if (string.IsNullOrEmpty(connectionString))
        {
            if (builder.Environment.IsProduction())
                throw new InvalidOperationException("ConnectionStrings:PostgreSQL must be set in production");
            connectionString = "Host=localhost;Database=titan;Username=titan;Password=titan";
        }

        builder.Services.AddDbContext<TitanDbContext>(options => options.UseNpgsql(connectionString));

        // Cache
        builder.Services.AddMemoryCache();
        builder.Services.AddSingleton<ICacheService, MemoryCacheService>();

        // Repositories
        builder.Services.AddScoped<IProductRepository, ProductRepository>();
        builder.Services.AddScoped<IBatchRepository, BatchRepository>();
        builder.Services.AddScoped<IWeightRecordRepository, WeightRecordRepository>();

        // Data directory for JSON files (EPC counter, weight records)
        var dataDir = builder.Configuration.GetValue<string>("DataDir")
                      ?? Path.Combine(AppContext.BaseDirectory, "data");
        Directory.CreateDirectory(dataDir);

        // Services — JSON-first, no DB in hot path
        builder.Services.AddSingleton<IEpcGenerator>(sp =>
            new JsonFileEpcGenerator(dataDir, "3034257BF7194E4",
                sp.GetService<ILogger<JsonFileEpcGenerator>>()));

        builder.Services.AddSingleton(sp =>
            new JsonFileRecordStore(dataDir,
                sp.GetService<ILogger<JsonFileRecordStore>>()));

        builder.Services.AddSingleton<BatchProcessingService>();
        builder.Services.AddSingleton<IElixirBridgeClient, ElixirBridgeClient>();

        // Hardware
        builder.Services.AddSingleton<IScalePort, SerialScalePort>();
        builder.Services.AddSingleton<IPrinterTransport, DeviceFilePrinter>();

        // Hosted Services
        builder.Services.AddHostedService<ScaleReadingService>();
        builder.Services.AddHostedService<DataSyncService>();
        builder.Services.AddHostedService<DatabaseSyncService>();
        builder.Services.AddHostedService<TuiHostedService>();

        // Health Checks
        builder.Services.AddHealthChecks()
            .AddDbContextCheck<TitanDbContext>("postgresql", HealthStatus.Unhealthy)
            .AddCheck<ScaleHealthCheck>("scale");

        // Kestrel on port 8080 for health checks
        builder.WebHost.UseUrls("http://+:8080");

        var app = builder.Build();

        // Health check endpoints (K8s liveness/readiness)
        app.MapHealthChecks("/health/live", new Microsoft.AspNetCore.Diagnostics.HealthChecks.HealthCheckOptions
        {
            Predicate = _ => false // Just checks if process is alive
        });
        app.MapHealthChecks("/health/ready", new Microsoft.AspNetCore.Diagnostics.HealthChecks.HealthCheckOptions
        {
            Predicate = _ => true // Checks all dependencies
        });

        // Ensure database is created
        using (var scope = app.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<TitanDbContext>();
            await db.Database.MigrateAsync();
        }

        // Graceful shutdown
        var lifetime = app.Services.GetRequiredService<IHostApplicationLifetime>();
        var logger = app.Services.GetRequiredService<ILogger<Program>>();
        lifetime.ApplicationStopping.Register(() =>
        {
            logger.LogInformation("TITAN Core shutting down gracefully...");
        });

        logger.LogInformation("TITAN Core started. Health: http://+:8080/health/ready");
        await app.RunAsync();
    }
}
